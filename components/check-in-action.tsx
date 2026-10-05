"use client";

import { useActionState } from "react";
import { LoaderCircle, LogIn } from "lucide-react";
import { checkInReservationAction, type ActionState } from "@/app/actions";

export function CheckInAction({ reservationId }: { reservationId: string }) {
  const [state, action, pending] = useActionState(checkInReservationAction, {} as ActionState);
  return <div className="checkin-action"><form action={action}><input type="hidden" name="reservation_id" value={reservationId}/><button className="button button-primary" disabled={pending || state.success}>{pending ? <LoaderCircle className="spin" size={14}/> : <LogIn size={14}/>} {state.success ? "Checked in" : pending ? "Checking in" : "Check in"}</button></form>{state.error && <small className="checkin-error" role="alert">{state.error}</small>}</div>;
}
