import json
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime

import boto3
import psycopg2
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

sqs = boto3.client("sqs", region_name=os.environ["AWS_REGION"])


CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS reservations (
    reservation_id UUID PRIMARY KEY,
    concert_id     VARCHAR NOT NULL,
    user_id        VARCHAR NOT NULL,
    ticket_type    VARCHAR NOT NULL,
    quantity       INTEGER NOT NULL,
    status         VARCHAR NOT NULL,
    created_at     TIMESTAMP NOT NULL,
    updated_at     TIMESTAMP NOT NULL
);
CREATE INDEX IF NOT EXISTS reservations_inventory_idx
ON reservations (concert_id, ticket_type, status);
"""


def get_connection():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=10,
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(CREATE_TABLE_SQL)
        conn.commit()
    finally:
        conn.close()
    yield


app = FastAPI(title="ticket-api", lifespan=lifespan)


class ReserveRequest(BaseModel):
    concert_id: str
    user_id: str
    ticket_type: str
    quantity: int


@app.post("/reserve")
def reserve(req: ReserveRequest):
    reservation_id = str(uuid.uuid4())
    now = datetime.utcnow()

    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO reservations
                    (reservation_id, concert_id, user_id, ticket_type, quantity, status, created_at, updated_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    reservation_id,
                    req.concert_id,
                    req.user_id,
                    req.ticket_type,
                    req.quantity,
                    "pending",
                    now,
                    now,
                ),
            )
        conn.commit()

        # Enqueue only after the commit, so the worker never gets a reservation it can't see yet.
        # MessageGroupId = concert_id keeps each concert's reservations in arrival order.
        try:
            sqs.send_message(
                QueueUrl=os.environ["SQS_QUEUE_URL"],
                MessageBody=json.dumps(
                    {
                        "reservation_id": reservation_id,
                        "concert_id": req.concert_id,
                        "user_id": req.user_id,
                        "ticket_type": req.ticket_type,
                        "quantity": req.quantity,
                    }
                ),
                MessageGroupId=req.concert_id,
                MessageDeduplicationId=reservation_id,
            )
        except (BotoCoreError, ClientError):
            with conn.cursor() as cur:
                cur.execute("DELETE FROM reservations WHERE reservation_id = %s", (reservation_id,))
            conn.commit()
            raise HTTPException(status_code=503, detail="Could not enqueue reservation, try again")
    finally:
        conn.close()

    return {
        "reservation_id": reservation_id,
        "concert_id": req.concert_id,
        "status": "pending",
    }

@app.get("/reservation/{reservation_id}")
def get_reservation(reservation_id: uuid.UUID):
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute("SELECT concert_id, ticket_type, quantity, status FROM reservations WHERE reservation_id = %s", (str(reservation_id),))
            row = cur.fetchone()
    finally:
        conn.close()
    if row is None:
        raise HTTPException(status_code=404, detail="Reservation not found")
    return {"reservation_id": str(reservation_id), "concert_id": row[0], "ticket_type": row[1], "quantity": row[2], "status": row[3]}