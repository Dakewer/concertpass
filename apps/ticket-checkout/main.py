from fastapi import FastAPI
from pydantic import BaseModel, Field
from uuid import UUID

app = FastAPI(title="ticket-checkout")


class CheckoutRequest(BaseModel):
    reservation_id: UUID
    quantity: int = Field(gt=0, strict=True)


@app.post("/checkout")
def checkout(req: CheckoutRequest):
    return {"message": "Success"}
