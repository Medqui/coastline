"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import { ArrowDownLeft, ArrowUpRight, Check, CircleDollarSign, CreditCard, Plus, TrendingUp, X } from "lucide-react";
import { recordSubscriptionReceipt, type ReceiptActionState } from "@/app/platform/actions";
import { plans, type PlatformHotel, type PlatformRevenueReport, type SubscriptionReceipt } from "@/lib/saas/types";
import { naira } from "@/lib/saas/pricing";
import { billingDateInput } from "@/lib/saas/upgrades";

const monthName = (month: string) => new Date(`${month}-01T12:00:00Z`).toLocaleDateString("en-NG", { month: "short", year: "2-digit", timeZone: "Africa/Lagos" });
const methods = { bank_transfer: "Bank transfer", cash: "Cash", card: "Card", other: "Other" };
const displayDate = (value: string) => new Date(`${value}T12:00:00+01:00`).toLocaleDateString("en-NG", { day: "numeric", month: "short", year: "numeric", timeZone: "Africa/Lagos" });

export function PlatformRevenue({ report, hotels, includeTests, setIncludeTests }: { report: PlatformRevenueReport | null; hotels: PlatformHotel[]; includeTests: boolean; setIncludeTests: (value: boolean) => void }) {
  const [range, setRange] = useState("6");
  const [editor, setEditor] = useState<{ requestId: string; refund?: SubscriptionReceipt }>();
  if (!report) return <section className="panel plan-gate"><CircleDollarSign size={26}/><h2>Revenue data is unavailable</h2><p>Refresh to try again. Revenue reporting needs the latest database update.</p></section>;
  const months = report.months.slice(-Number(range));
  const chartMax = Math.max(1, ...months.flatMap(month => [Number(month.received_kobo), Number(month.refunded_kobo)]));
  const netMonth = Number(report.received_this_month_kobo) - Number(report.refunded_this_month_kobo);
  const netTotal = Number(report.received_all_time_kobo) - Number(report.refunded_all_time_kobo);
  return <>
    <div className="platform-revenue-toolbar"><label className="platform-test-toggle"><input type="checkbox" checked={includeTests} onChange={event => setIncludeTests(event.target.checked)}/>Include test workspaces</label><button className="button button-primary" disabled={!hotels.length} onClick={() => setEditor({ requestId: crypto.randomUUID() })}><Plus size={16}/>Record payment</button></div>
    <div className="platform-summary platform-revenue-summary">
      <RevenueStat label="Monthly recurring revenue" value={Number(report.mrr_kobo)} note={`${report.paying_customers} active subscriptions · agreed monthly fees`} icon={TrendingUp}/>
      <RevenueStat label="Net received this month" value={netMonth} note={`${naira(Number(report.received_this_month_kobo))} received − ${naira(Number(report.refunded_this_month_kobo))} refunded`} icon={ArrowDownLeft}/>
      <RevenueStat label="Net received all time" value={netTotal} note="Recorded subscription payments minus refunds" icon={CircleDollarSign}/>
      <RevenueStat label="Annual recurring revenue" value={Number(report.mrr_kobo) * 12} note="Current monthly revenue × 12 · projection" icon={CreditCard}/>
    </div>
    <div className={`platform-revenue-notice ${Number(report.at_risk_mrr_kobo) ? "" : "all-clear"}`}><strong>{Number(report.at_risk_mrr_kobo) ? `${naira(Number(report.at_risk_mrr_kobo))} monthly revenue needs attention` : "No overdue subscription revenue"}</strong><span>From overdue or expired active subscriptions. Trials and pilots are excluded from recurring revenue.</span></div>
    <section className="panel platform-revenue-chart"><div className="card-heading"><div><strong>Subscription collections</strong><small>Payments and refunds by month · {monthName(billingDateInput(report.as_of).slice(0,7))}</small></div><select className="select-control" aria-label="Revenue chart period" value={range} onChange={event => setRange(event.target.value)}><option value="6">6 months</option><option value="12">12 months</option></select></div><div className="platform-revenue-legend"><span><i/>Payments</span><span><i/>Refunds</span></div><div className="table-wrap"><div className="platform-revenue-bars">{months.map(month => <div className="platform-revenue-month" key={month.month}><div className="platform-revenue-bar-pair" role="img" aria-label={`${monthName(month.month)}: ${naira(Number(month.received_kobo))} received, ${naira(Number(month.refunded_kobo))} refunded`}><span style={{ height: `${Number(month.received_kobo) / chartMax * 100}%` }} title={`Payments ${naira(Number(month.received_kobo))}`}/><span style={{ height: `${Number(month.refunded_kobo) / chartMax * 100}%` }} title={`Refunds ${naira(Number(month.refunded_kobo))}`}/></div><strong>{monthName(month.month)}</strong><small>{naira(Number(month.received_kobo) - Number(month.refunded_kobo))}</small></div>)}</div></div>{!months.some(month => Number(month.received_kobo) || Number(month.refunded_kobo)) && <p className="platform-revenue-empty">No subscription payments recorded in this period.</p>}</section>
    <section className="panel platform-revenue-tiers"><div className="card-heading"><div><strong>Revenue by tier</strong><small>Recurring revenue uses current plans. Collections use the plan recorded with each payment.</small></div></div><div className="table-wrap"><table><thead><tr><th>Tier</th><th>Launch price / month</th><th>Active subscriptions</th><th>Recurring / month</th><th>Net received this month</th></tr></thead><tbody>{plans.map(plan => { const tier = report.tiers.find(item => item.code === plan.code); return <tr key={plan.code}><td><strong>{plan.name}</strong></td><td>{plan.code === "group" ? "From " : ""}{naira(Number(report.prices[plan.code]))}</td><td>{tier?.customers ?? 0}</td><td>{naira(Number(tier?.mrr_kobo ?? 0))}</td><td>{naira(Number(tier?.net_this_month_kobo ?? 0))}</td></tr>; })}</tbody></table></div></section>
    <section className="panel platform-revenue-receipts"><div className="card-heading"><div><strong>Payment history</strong><small>Latest 50 entries · totals above include the full history.</small></div></div>{!report.receipts.length ? <div className="empty-state"><CircleDollarSign size={24}/><p>Record your first subscription payment to start tracking collections.</p></div> : <div className="platform-receipt-list">{report.receipts.map(receipt => <article className="platform-receipt-row" key={receipt.id}><span className={`platform-receipt-icon ${receipt.entry_type === "refund" ? "refund" : ""}`}>{receipt.entry_type === "refund" ? <ArrowUpRight size={19}/> : <ArrowDownLeft size={19}/>}</span><div className="platform-receipt-info"><strong>{receipt.organization_name}</strong><small>{displayDate(receipt.received_on)} · {plans.find(plan => plan.code === receipt.plan_code)?.name} · {methods[receipt.method as keyof typeof methods] ?? receipt.method}</small><small>{receipt.reference} · {receipt.note}</small>{receipt.is_test && <span className="status-pill amber-pill">Test entry</span>}</div><div className="platform-receipt-amount"><strong className={receipt.entry_type === "refund" ? "negative" : "positive"}>{receipt.entry_type === "refund" ? "−" : "+"}{naira(Number(receipt.amount_kobo))}</strong><small>{receipt.entry_type === "refund" ? "Refund recorded" : Number(receipt.refunded_kobo) > 0 ? `${naira(Number(receipt.refunded_kobo))} refunded` : "Payment recorded"}</small>{receipt.entry_type === "payment" && Number(receipt.refunded_kobo) < Number(receipt.amount_kobo) && <button className="text-button" onClick={() => setEditor({ requestId: crypto.randomUUID(), refund: receipt })}>Record refund</button>}</div></article>)}</div>}</section>
    <p className="platform-footnote">Collections reflect payments you record as received. Online payment collection is not connected. Recording a payment or refund does not move money or change a customer’s plan.</p>
    {editor && <ReceiptEditor key={editor.requestId} requestId={editor.requestId} refund={editor.refund} hotels={hotels} report={report} close={() => setEditor(undefined)}/>}
  </>;
}
function RevenueStat({ label, value, note, icon: Icon }: { label: string; value: number; note: string; icon: typeof TrendingUp }) {
  return <article className="metric-card"><div className="metric-label">{label}<Icon size={18}/></div><strong className="metric-value">{naira(value)}</strong><small className="metric-foot">{note}</small></article>;
}
function ReceiptEditor({ requestId, refund, hotels, report, close }: { requestId: string; refund?: SubscriptionReceipt; hotels: PlatformHotel[]; report: PlatformRevenueReport; close: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [customerId, setCustomerId] = useState(refund?.organization_id ?? hotels[0]?.id ?? "");
  const hotel = hotels.find(item => item.id === customerId);
  const [planCode, setPlanCode] = useState(refund?.plan_code ?? hotel?.subscription.plan_code ?? "business");
  const suggestedAmount = (hotel?.monthly_fee_kobo ?? report.prices[planCode]) / 100;
  const refundable = refund ? (Number(refund.amount_kobo) - Number(refund.refunded_kobo)) / 100 : null;
  const [amount, setAmount] = useState(String(refundable ?? suggestedAmount));
  const [state, action, pending] = useActionState(recordSubscriptionReceipt, {} as ReceiptActionState);
  useEffect(() => {
    const panel = dialog.current; const previous = document.activeElement as HTMLElement | null;
    const overflow = document.body.style.overflow;
    panel?.showModal(); document.body.style.overflow = "hidden";
    return () => { panel?.close(); document.body.style.overflow = overflow; previous?.focus(); };
  }, []);
  return <dialog ref={dialog} className="platform-subscription-modal" aria-labelledby="receipt-editor-title" onCancel={event => { event.preventDefault(); if (!pending) close(); }}>
    <header className="platform-editor-header"><div><div className="eyebrow">SUBSCRIPTION COLLECTIONS</div><h2 id="receipt-editor-title">{state.success ? "Entry recorded" : refund ? "Record a refund" : "Record a payment"}</h2><p>{refund ? `Original payment: ${refund.reference} · ${refund.organization_name}` : "Record subscription money you have already received."}</p></div><button className="icon-button" disabled={pending} aria-label="Close payment form" onClick={close}><X size={20}/></button></header>
    {state.success ? <><div className="platform-editor-fields platform-upgrade-success"><span className="platform-upgrade-success-icon"><Check size={24}/></span><p role="status">The {refund ? "refund" : "payment"} has been saved. Your revenue totals and payment history have been updated.</p></div><footer className="platform-editor-actions"><button autoFocus className="button button-primary" onClick={close}>Done</button></footer></> : <form action={action} className="platform-subscription-form"><input type="hidden" name="request_id" value={requestId}/><input type="hidden" name="entry_type" value={refund ? "refund" : "payment"}/>{refund && <><input type="hidden" name="organization_id" value={refund.organization_id}/><input type="hidden" name="original_payment_id" value={refund.id}/><input type="hidden" name="plan" value={refund.plan_code}/></>}
      <fieldset disabled={pending} className="platform-editor-fields platform-receipt-fields">
        <p className="platform-editor-note">{refund ? `Only record a refund you have already issued. Remaining refundable amount: ${naira((refundable ?? 0) * 100)}.` : "Confirm the money has reached your account before recording it. This form does not charge the hotel or activate its subscription."}</p>
        {!refund && <div className="platform-editor-row"><label>Hotel business<select name="organization_id" required value={customerId} onChange={event => { const next = hotels.find(item => item.id === event.target.value); const code = next?.subscription.plan_code ?? "business"; setCustomerId(event.target.value); setPlanCode(code); setAmount(String((next?.monthly_fee_kobo ?? report.prices[code]) / 100)); }}>{hotels.map(customer => <option value={customer.id} key={customer.id}>{customer.name}</option>)}</select></label><label>Plan paid for<select name="plan" value={planCode} onChange={event => { const code = event.target.value as typeof planCode; setPlanCode(code); setAmount(String(report.prices[code] / 100)); }}>{plans.map(plan => <option value={plan.code} key={plan.code}>{plan.name}</option>)}</select></label></div>}
        <div className="platform-editor-row"><label>Amount (₦)<input name="amount" type="number" min="0.01" max={refundable ?? undefined} step="0.01" required value={amount} onChange={event => setAmount(event.target.value)}/></label><label>{refund ? "Refund date" : "Received date"}<input type="date" name="received_on" required min={refund?.received_on} max={billingDateInput(report.as_of)} defaultValue={billingDateInput(report.as_of)}/></label></div>
        <label>Payment method<select name="method" defaultValue="bank_transfer">{Object.entries(methods).map(([code, label]) => <option value={code} key={code}>{label}</option>)}</select></label>
        <label>Unique reference<input name="reference" required minLength={2} maxLength={150} placeholder={refund ? "Bank refund reference or refund receipt number" : "Bank transaction reference or receipt number"}/></label>
        <label>Note<textarea name="note" required minLength={5} maxLength={500} rows={2} placeholder={refund ? "Reason for the refund" : "For example, October Business subscription"}/></label>
        {state.error && <p className="form-error" role="alert">{state.error}</p>}
      </fieldset><footer className="platform-editor-actions"><button type="button" className="button" disabled={pending} onClick={close}>Cancel</button><button type="submit" className="button button-primary" disabled={pending}>{pending ? "Saving…" : refund ? "Record refund" : "Record payment"}</button></footer>
    </form>}
  </dialog>;
}
