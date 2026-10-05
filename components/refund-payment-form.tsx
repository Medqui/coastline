"use client";

import { useActionState, useEffect, useState } from "react";
import { refundPaymentAction, type ActionState } from "@/app/actions";

export function RefundPaymentForm({ paymentId, maxKobo }: { paymentId: string; maxKobo: number }) {
  const [state, action, pending] = useActionState(refundPaymentAction, {} as ActionState);
  const [key, setKey] = useState("");
  useEffect(() => { setKey(crypto.randomUUID()); }, []);
  if (state.success) return <p className="folio-success">Refund requested. Another owner or manager must approve it before money is returned.</p>;
  return <form action={action} className="reservation-form folio-form">
    <input type="hidden" name="payment_id" value={paymentId}/><input type="hidden" name="idempotency_key" value={key}/>
    <div className="reservation-form-row"><label>Refund (₦)<input name="amount" type="number" min="0.01" max={(maxKobo/100).toFixed(2)} step="0.01" required/></label><label>Reason<input name="reason" minLength={5} maxLength={500} required placeholder="Why is this refunded?"/></label></div>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}
    <button className="button" disabled={pending || !key || maxKobo<=0}>Request refund</button>
  </form>;
}
