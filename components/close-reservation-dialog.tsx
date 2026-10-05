"use client";

import { useActionState } from "react";
import { X } from "lucide-react";
import { closeReservationAction, type ActionState } from "@/app/actions";
import type { LiveStay } from "@/components/hotel-dashboard";

export function CloseReservationDialog({ stay, onClose }: { stay: LiveStay; onClose: () => void }) {
  const [state, action, pending] = useActionState(closeReservationAction, {} as ActionState);
  return <div className="modal-backdrop" onMouseDown={event => { if (event.target === event.currentTarget) onClose(); }}><section className="reservation-modal" role="dialog" aria-modal="true" aria-labelledby="close-reservation-title">
    <button className="modal-close" onClick={onClose} aria-label="Close"><X size={18}/></button>
    {state.success ? <div className="modal-success"><h2>Reservation updated</h2><p>The room has been released for these dates.</p><button className="button button-primary" onClick={onClose}>Done</button></div> : <>
      <div className="eyebrow">RESERVATION CONTROL</div><h2 id="close-reservation-title">Close {stay.guest}’s booking</h2>
      <p className="modal-subtitle">Reservation {stay.id.slice(0,8).toUpperCase()} · {stay.arrival}–{stay.departure}</p>
      <form action={action} className="reservation-form"><input type="hidden" name="reservation_id" value={stay.id}/>
        <label>Status<select name="status" required><option value="cancelled">Cancelled</option><option value="no_show">No-show</option></select></label>
        <label>Reason<input name="reason" required minLength={3} maxLength={300} placeholder="Guest request, did not arrive…"/></label>
        {state.error && <p className="form-error" role="alert">{state.error}</p>}
        <div className="modal-actions"><button type="button" className="button" onClick={onClose}>Keep booking</button><button className="button button-primary" disabled={pending}>Save change</button></div>
      </form>
    </>}
  </section></div>;
}
