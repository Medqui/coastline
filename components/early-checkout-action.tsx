"use client";
import { useActionState } from "react";
import { LoaderCircle } from "lucide-react";
import { earlyCheckOutReservationAction, type ActionState } from "@/app/actions";
export function EarlyCheckoutAction({ reservationId }: { reservationId: string }) {
  const [state, action, pending] = useActionState(earlyCheckOutReservationAction, {} as ActionState);
  return <form action={action} className="inline-action"><input type="hidden" name="reservation_id" value={reservationId}/><button className="text-button" disabled={pending}>{pending ? <LoaderCircle size={13} className="spin"/> : null}Early checkout</button>{state.error && <span className="form-error">{state.error}</span>}</form>;
}
