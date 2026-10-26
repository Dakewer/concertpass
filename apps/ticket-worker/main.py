import json
import logging
import os
import time

import boto3
import psycopg2
import requests

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ticket-worker")

SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
CHECKOUT_URL = os.environ["CHECKOUT_URL"]

sqs = boto3.client("sqs", region_name=os.environ["AWS_REGION"])
concerts = boto3.resource("dynamodb", region_name=os.environ["AWS_REGION"]).Table(os.environ["EVENTS_TABLE"])

# Postgres doesn't allow FOR UPDATE directly on an aggregate, so the rows are locked in a
# subquery and summed outside it. Pending rows are locked too: every reservation already
# exists as a pending row before its message is processed, so two workers handling the same
# concert/ticket_type always collide on at least one row, and the second one waits for the
# first to commit and then counts its result.
LOCK_AND_COUNT_SQL = """
SELECT COALESCE(SUM(quantity) FILTER (WHERE status IN ('booked', 'confirmed')), 0)
FROM (
    SELECT quantity, status
    FROM reservations
    WHERE concert_id = %s
      AND ticket_type = %s
      AND status IN ('pending', 'booked', 'confirmed')
    ORDER BY reservation_id
    FOR UPDATE
) AS active
"""

SET_STATUS_SQL = """
UPDATE reservations
SET status = %s, updated_at = NOW() AT TIME ZONE 'UTC'
WHERE reservation_id = %s AND status = %s
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


def get_capacity(concert_id, ticket_type):
    item = concerts.get_item(Key={"concert_id": concert_id}).get("Item")
    if item is None:
        return 0
    return int(item["capacity"].get(ticket_type, 0))


def book_or_reject(conn, reservation_id, concert_id, ticket_type, quantity):
    capacity = get_capacity(concert_id, ticket_type)

    with conn, conn.cursor() as cur:
        cur.execute(LOCK_AND_COUNT_SQL, (concert_id, ticket_type))
        sold = cur.fetchone()[0]
        if sold + quantity <= capacity:
            cur.execute(SET_STATUS_SQL, ("booked", reservation_id, "pending"))
            return "booked"
        conn.rollback()

    with conn, conn.cursor() as cur:
        cur.execute(SET_STATUS_SQL, ("rejected", reservation_id, "pending"))
    return "rejected"


def handle(conn, reservation_id):
    with conn, conn.cursor() as cur:
        cur.execute(
            "SELECT concert_id, ticket_type, quantity, status FROM reservations WHERE reservation_id = %s",
            (reservation_id,),
        )
        row = cur.fetchone()
    if row is None:
        log.warning("Reservation %s not found, dropping message", reservation_id)
        return
    concert_id, ticket_type, quantity, status = row

    # SQS delivers at least once, so each step checks the current status: a redelivered
    # message picks up where the previous attempt stopped instead of booking twice.
    if status == "pending":
        status = book_or_reject(conn, reservation_id, concert_id, ticket_type, quantity)
        log.info("Reservation %s (%s x%d %s): %s", reservation_id, concert_id, quantity, ticket_type, status)

    if status == "booked":
        resp = requests.post(
            f"{CHECKOUT_URL}/checkout",
            json={"reservation_id": reservation_id, "quantity": quantity},
            timeout=10,
        )
        resp.raise_for_status()
        with conn, conn.cursor() as cur:
            cur.execute(SET_STATUS_SQL, ("confirmed", reservation_id, "booked"))
        log.info("Reservation %s: confirmed", reservation_id)


def process_batch(messages):
    conn = get_connection()
    try:
        failed_groups = set()
        for msg in messages:
            group = msg["Attributes"]["MessageGroupId"]
            # If a message fails, leave the rest of its group in the queue too, so they are
            # retried after it in their original order.
            if group in failed_groups:
                continue
            try:
                handle(conn, json.loads(msg["Body"])["reservation_id"])
            except Exception:
                log.exception("Failed to process message %s", msg["MessageId"])
                failed_groups.add(group)
                continue
            sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])
    finally:
        conn.close()


def main():
    log.info("Polling %s", SQS_QUEUE_URL)
    while True:
        try:
            messages = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,
                MessageSystemAttributeNames=["MessageGroupId"],
            ).get("Messages", [])
            if messages:
                process_batch(messages)
        except Exception:
            log.exception("Polling iteration failed, retrying in 5s")
            time.sleep(5)


if __name__ == "__main__":
    main()
