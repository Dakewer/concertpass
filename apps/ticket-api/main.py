import os
import uuid
from datetime import datetime

import psycopg2
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()


class ReserveRequest(BaseModel):
    concert_id: str
    user_id: str
    ticket_type: str
    quantity: int


def get_connection():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )


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
                    "confirmed",
                    now,
                    now,
                ),
            )
        conn.commit()
    finally:
        conn.close()

    return {
        "reservation_id": reservation_id,
        "concert_id": req.concert_id,
        "status": "confirmed",
    }
