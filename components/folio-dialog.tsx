"use client";

import { useActionState, useEffect, useState } from "react";
import { LoaderCircle, X } from "lucide-react";
import {
  applyDepositAction, checkOutReservationAction, postFolioChargeAction, postRoomNightsAction,
  recordFolioPaymentAction, type ActionState,
} from "@/app/actions";
import type { LiveDeposit, LiveFolio, LivePayment, LiveStay, PaymentMethodOption, DepartmentOption } from "@/components/hotel-dashboard";
import { RefundPaymentForm } from "@/components/refund-payment-form";

function amount(kobo: number) {
  return new Intl.NumberFormat("en-NG", { style: "currency", currency: "NGN", maximumFractionDigits: 2 }).format(kobo / 100);
}

function Submit({ pending, label }: { pending: boolean; label: string }) {
  return <button className="button button-primary" disabled={pending}>{pending && <LoaderCircle className="spin" size={14}/>} {label}</button>;
}

function ChargeForm({ folioId, departments }: { folioId: string; departments: DepartmentOption[] }) {
  const [state, action, pending] = useActionState(postFolioChargeAction, {} as ActionState);
  const [key, setKey] = useState("");
  useEffect(() => { setKey(crypto.randomUUID()); }, []);
  if (state.success) return <p className="folio-success">Charge posted. Close and reopen the folio to add another.</p>;
  return <form action={action} className="reservation-form folio-form">
    <input type="hidden" name="folio_id" value={folioId}/><input type="hidden" name="idempotency_key" value={key}/>
    <div className="reservation-form-row"><label>Description<input name="description" required minLength={2} placeholder="Laundry, minibar, meal…"/></label><label>Amount (₦)<input name="amount" type="number" min="0.01" step="0.01" required/></label></div>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}
    <label>Department<select name="department_id" required defaultValue={departments.find(department => department.code === "services")?.id}>{departments.map(department => <option key={department.id} value={department.id}>{department.name}</option>)}</select></label>
    <Submit pending={pending || !key || !departments.length} label="Post charge"/>
  </form>;
}

function PaymentForm({ folioId, balance, methods }: { folioId: string; balance: number; methods: PaymentMethodOption[] }) {
  const [state, action, pending] = useActionState(recordFolioPaymentAction, {} as ActionState);
  const [key, setKey] = useState("");
  useEffect(() => { setKey(crypto.randomUUID()); }, []);
  if (state.success) return <p className="folio-success">Payment recorded. Close and reopen the folio to collect another.</p>;
  return <form action={action} className="reservation-form folio-form">
    <input type="hidden" name="folio_id" value={folioId}/><input type="hidden" name="idempotency_key" value={key}/>
    <div className="reservation-form-row"><label>Amount (₦)<input name="amount" type="number" min="0.01" max={(balance / 100).toFixed(2)} step="0.01" required/></label><label>Method<select name="payment_method_id" required>{methods.map(method => <option key={method.id} value={method.id}>{method.name}</option>)}</select></label></div>
    <label>Reference <span className="optional">Optional</span><input name="reference" placeholder="Transfer or POS reference"/></label>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}
    <Submit pending={pending || !key || !methods.length || balance <= 0} label="Record payment"/>
  </form>;
}

function ApplyDepositForm({ deposit, balance }: { deposit: LiveDeposit; balance: number }) {
  const [state, action, pending] = useActionState(applyDepositAction, {} as ActionState);
  const [key, setKey] = useState("");
  useEffect(() => { setKey(crypto.randomUUID()); }, []);
  const available = deposit.amountKobo-deposit.appliedKobo-deposit.refundedKobo;
  if (state.success) return <p className="folio-success">Deposit applied. Close and reopen to see the updated balance.</p>;
  return <form action={action} className="reservation-form folio-form"><input type="hidden" name="deposit_id" value={deposit.id}/><input type="hidden" name="idempotency_key" value={key}/>
    <label>Apply deposit (₦)<input name="amount" type="number" min="0.01" step="0.01" max={(Math.min(available,balance)/100).toFixed(2)} required/></label>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}
    <button className="button button-primary" disabled={pending || !key || available<=0 || balance<=0}>Apply to balance</button>
  </form>;
}

export function FolioDialog({ stay, folio, methods, departments, deposits, payments, role, onClose }: {
  stay: LiveStay; folio: LiveFolio | undefined; methods: PaymentMethodOption[]; departments: DepartmentOption[];
  deposits: LiveDeposit[]; payments: LivePayment[]; role: string; onClose: () => void;
}) {
  const [nightState, nightAction, nightPending] = useActionState(postRoomNightsAction, {} as ActionState);
  const [checkoutState, checkoutAction, checkoutPending] = useActionState(checkOutReservationAction, {} as ActionState);
  const balance = folio?.items.reduce((sum, item) => sum + item.totalKobo, 0) ?? 0;
  const folioDeposits = deposits.filter(deposit => deposit.folioId === folio?.id);
  const folioPayments = payments.filter(payment => payment.folioId === folio?.id);
  const unappliedDeposits = folioDeposits.reduce((sum,deposit) => sum + deposit.amountKobo-deposit.appliedKobo-deposit.refundedKobo,0);
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Africa/Lagos", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
  return <div className="modal-backdrop" onMouseDown={event => { if (event.target === event.currentTarget) onClose(); }}><section className="reservation-modal folio-modal" role="dialog" aria-modal="true" aria-labelledby="folio-title">
    <button className="modal-close" onClick={onClose} aria-label="Close"><X size={18}/></button>
    <div className="eyebrow">GUEST ACCOUNT</div><h2 id="folio-title">{stay.guest} · {stay.room}</h2>
    <button type="button" className="button folio-print" onClick={() => window.print()}>Print folio</button>
    <p className="modal-subtitle">{stay.arrival}–{stay.departure} · Reservation {stay.id.slice(0,8).toUpperCase()}</p>
    {stay.pricingReason && <div className="pricing-approval modal-subtitle"><strong>{stay.complimentary ? "Complimentary stay" : "Approved room rate"}</strong><p>{stay.nightlyRateKobo === undefined ? "Agreed rates vary by night; see the quote below." : `${amount(stay.nightlyRateKobo)}/night`}</p><p>Approval reason: {stay.pricingReason}</p></div>}
    {stay.nightRates && <details className="nightly-quote"><summary>Agreed nightly room prices · quote</summary><div className="table-wrap"><table><thead><tr><th>Night</th><th>Agreed rate</th></tr></thead><tbody>{stay.nightRates.map(night => <tr key={night.date}><td>{night.date}</td><td>{amount(night.agreedKobo)}</td></tr>)}</tbody></table></div><p>Room total: {stay.amount}. Charges below post after each completed night.</p></details>}
    {!folio ? <div className="empty-state">The folio has not loaded. Close and reopen this stay.</div> : <>
      <div className="folio-total"><span>Outstanding balance</span><strong>{amount(balance)}</strong></div>
      <div className="folio-items"><div className="folio-items-head"><strong>Posted activity</strong><small>Room quotes are charged after each completed night.</small></div>
        {folio.items.length ? folio.items.map(item => <div className="folio-item" key={item.id}><div><strong>{item.description}</strong><small>{item.serviceDate} · {item.type.replace("_", " ")}</small></div><b>{amount(item.totalKobo)}</b></div>) : <div className="empty-state">No charges or payments posted yet.</div>}
      </div>
      {folioDeposits.length>0 && <div className="folio-section"><h3>Guest advances</h3>{folioDeposits.map(deposit => <div className="deposit-row" key={deposit.id}><p>Received {amount(deposit.amountKobo)} · Unapplied {amount(deposit.amountKobo-deposit.appliedKobo-deposit.refundedKobo)}</p>{stay.status === "checked_in" && <ApplyDepositForm deposit={deposit} balance={balance}/>}</div>)}</div>}
      {stay.status === "checked_in" && <>
        <form action={nightAction} className="folio-inline-action"><input type="hidden" name="reservation_id" value={stay.id}/><div><strong>Post completed room nights</strong><small>Safe to run again; each night posts only once.</small></div><Submit pending={nightPending} label="Post due nights"/></form>
        {nightState.error && <p className="form-error" role="alert">{nightState.error}</p>}{nightState.success && <p className="folio-success">Due room nights updated.</p>}
        <div className="folio-section"><h3>Add an extra charge</h3><ChargeForm folioId={folio.id} departments={departments}/></div>
        <div className="folio-section"><h3>Collect payment</h3><PaymentForm folioId={folio.id} balance={balance} methods={methods}/></div>
        {["owner","manager","front_desk"].includes(role) && folioPayments.length>0 && <div className="folio-section"><h3>Request a payment refund</h3>{folioPayments.map(payment => <div className="deposit-row" key={payment.id}><p>{payment.isDeposit ? "Deposit" : "Folio payment"} · {amount(payment.amountKobo)} · {new Date(payment.receivedAt).toLocaleDateString("en-NG")}</p><RefundPaymentForm paymentId={payment.id} maxKobo={payment.isDeposit ? (folioDeposits.find(deposit => deposit.paymentId === payment.id)?.amountKobo ?? 0) - (folioDeposits.find(deposit => deposit.paymentId === payment.id)?.appliedKobo ?? 0) - (folioDeposits.find(deposit => deposit.paymentId === payment.id)?.refundedKobo ?? 0) : payment.amountKobo}/></div>)}</div>}
        <form action={checkoutAction} className="folio-checkout"><input type="hidden" name="reservation_id" value={stay.id}/><p>Checkout is available on or after {stay.departure}, once the balance and unapplied deposits are zero. The room will move to “needs cleaning”.</p><Submit pending={checkoutPending || today < stay.departureDate || balance !== 0 || unappliedDeposits>0} label="Check out guest"/></form>
        {checkoutState.error && <p className="form-error" role="alert">{checkoutState.error}</p>}{checkoutState.success && <p className="folio-success">Guest checked out.</p>}
      </>}
    </>}
  </section></div>;
}
