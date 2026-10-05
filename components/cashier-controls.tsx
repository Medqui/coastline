"use client";

import { useActionState, useCallback, useEffect, useState } from "react";
import { LoaderCircle } from "lucide-react";
import { closeCashierShiftAction, openCashierShiftAction, reviewCashierShiftAction, reviewPaymentRefundAction, type ActionState } from "@/app/actions";
import { createClient } from "@/lib/supabase/client";
import { readWithRetry } from "@/lib/supabase/read-with-retry";

type Shift = { shift_id:string;cashier_user_id:string;cashier_email:string;opened_at:string;opening_float_kobo:number;status:string;expected_cash_kobo:number|null;counted_cash_kobo:number|null;variance_kobo:number|null;close_reason:string|null;tender_totals:Record<string,{received_kobo:number;refunded_kobo:number;net_kobo:number}>;closed_at:string|null };
type RefundRequest = { request_id:string;payment_id:string;amount_kobo:number;reason:string;status:string;requested_by:string;requester_email:string;requested_at:string;review_note:string|null };
const money=(value:number)=>new Intl.NumberFormat("en-NG",{style:"currency",currency:"NGN"}).format(value/100);

function OpenShift({propertyId,onSaved}:{propertyId:string;onSaved:()=>void}) {
  const [state,action,pending]=useActionState(openCashierShiftAction,{} as ActionState);
  const [key,setKey]=useState("");
  useEffect(()=>setKey(crypto.randomUUID()),[]);
  useEffect(()=>{if(state.success)onSaved();},[state.success,onSaved]);
  return <form action={action} className="reservation-form cashier-form"><input type="hidden" name="property_id" value={propertyId}/><input type="hidden" name="idempotency_key" value={key}/><label>Opening cash float (₦)<input name="opening_float" type="number" min="0" step="0.01" defaultValue="0" required/></label>{state.error&&<p className="form-error">{state.error}</p>}<button className="button button-primary" disabled={pending||!key}>{pending?"Opening…":"Open my shift"}</button></form>;
}

function CloseShift({shift,onSaved}:{shift:Shift;onSaved:()=>void}) {
  const [state,action,pending]=useActionState(closeCashierShiftAction,{} as ActionState);
  useEffect(()=>{if(state.success)onSaved();},[state.success,onSaved]);
  return <form action={action} className="reservation-form cashier-form"><input type="hidden" name="shift_id" value={shift.shift_id}/><label>Counted cash (₦)<input name="counted_cash" type="number" min="0" step="0.01" required/></label><label>Variance explanation <span className="optional">Required if cash differs</span><textarea name="reason" minLength={5} maxLength={500} rows={2}/></label>{state.error&&<p className="form-error">{state.error}</p>}<button className="button button-primary" disabled={pending}>{pending?"Checking…":"Close and reconcile"}</button></form>;
}

function ReviewShift({shift,onSaved}:{shift:Shift;onSaved:()=>void}) {
  const [state,action,pending]=useActionState(reviewCashierShiftAction,{} as ActionState);
  const [decision,setDecision]=useState("approve");
  useEffect(()=>{if(state.success)onSaved();},[state.success,onSaved]);
  return <form action={action} className="statement-inline-form"><input type="hidden" name="shift_id" value={shift.shift_id}/><select name="decision" value={decision} onChange={event=>setDecision(event.target.value)}><option value="approve">Approve variance</option><option value="reject">Reject and reopen</option></select><input name="note" minLength={decision==="reject"?5:0} maxLength={500} required={decision==="reject"} placeholder={decision==="reject"?"Why is this rejected?":"Review note (optional)"}/><button className="button" disabled={pending}>{pending?"Saving…":"Submit review"}</button>{state.error&&<p className="form-error">{state.error}</p>}</form>;
}

function ReviewRefund({request,onSaved}:{request:RefundRequest;onSaved:()=>void}) {
  const [state,action,pending]=useActionState(reviewPaymentRefundAction,{} as ActionState);
  const [decision,setDecision]=useState("approve");
  useEffect(()=>{if(state.success)onSaved();},[state.success,onSaved]);
  return <form action={action} className="statement-inline-form"><input type="hidden" name="request_id" value={request.request_id}/><select name="decision" value={decision} onChange={event=>setDecision(event.target.value)}><option value="approve">Approve and post</option><option value="reject">Reject request</option></select><input name="note" minLength={decision==="reject"?5:0} maxLength={500} required={decision==="reject"} placeholder={decision==="reject"?"Why is this rejected?":"Review note (optional)"}/><button className="button" disabled={pending}>{pending?"Saving…":"Submit review"}</button>{state.error&&<p className="form-error">{state.error}</p>}</form>;
}

export function CashierControls({propertyId,role}:{propertyId:string;role:string}) {
  const [shifts,setShifts]=useState<Shift[]>([]);const [refunds,setRefunds]=useState<RefundRequest[]>([]);const [userId,setUserId]=useState("");
  const [loading,setLoading]=useState(true);const [error,setError]=useState("");const [revision,setRevision]=useState(0);
  const saved=useCallback(()=>setRevision(value=>value+1),[]);
  useEffect(()=>{let active=true;setLoading(true);setError("");const supabase=createClient();Promise.all([
    supabase.auth.getUser(),readWithRetry(()=>supabase.rpc("get_cashier_shifts",{p_property_id:propertyId,p_limit:30})),readWithRetry(()=>supabase.rpc("get_refund_approval_requests",{p_property_id:propertyId,p_status:"pending"}))
  ]).then(([userResult,shiftResult,refundResult])=>{if(!active)return;setLoading(false);if(shiftResult.error||refundResult.error){setError("Cashier controls could not be loaded. Confirm migration 015 is installed.");setShifts([]);setRefunds([]);return;}setUserId(userResult.data.user?.id??"");setShifts((shiftResult.data??[])as Shift[]);setRefunds((refundResult.data??[])as RefundRequest[]);}).catch(()=>{if(active){setLoading(false);setError("Cashier controls are temporarily unavailable. Try refreshing.");}});return()=>{active=false};},[propertyId,revision]);
  const ownActive=shifts.find(shift=>shift.cashier_user_id===userId&&["open","pending_approval"].includes(shift.status));
  const canApprove=["owner","manager"].includes(role);
  return <section className="panel cashier-panel"><div className="panel-heading"><div><strong>Cashier shift and refund controls</strong><small>Payments attach to your open shift. Cash variances and refunds require a different owner or manager.</small></div><button className="button" onClick={saved}>Refresh</button></div>{error&&<p className="form-error report-error">{error}</p>}{loading?<p className="empty-state"><LoaderCircle className="spin" size={14}/> Loading cashier controls…</p>:<div className="cashier-layout"><div><h3>My cashier shift</h3>{!ownActive?<OpenShift propertyId={propertyId} onSaved={saved}/>:ownActive.status==="pending_approval"?<p className="demo-notice">Your shift is awaiting another manager or owner’s variance review.</p>:<><ShiftSummary shift={ownActive}/><CloseShift shift={ownActive} onSaved={saved}/></>}</div><div><h3>Pending reviews</h3>{canApprove?shifts.filter(shift=>shift.status==="pending_approval"&&shift.cashier_user_id!==userId).map(shift=><article className="maintenance-order" key={shift.shift_id}><strong>{shift.cashier_email} · {money(Number(shift.variance_kobo??0))} variance</strong><p>Expected {money(Number(shift.expected_cash_kobo??0))}; counted {money(Number(shift.counted_cash_kobo??0))}. {shift.close_reason}</p><ReviewShift shift={shift} onSaved={saved}/></article>):<p className="optional">Owners and managers review cash variances.</p>}{canApprove&&refunds.filter(request=>request.requested_by!==userId).map(request=><article className="maintenance-order" key={request.request_id}><strong>Refund {money(Number(request.amount_kobo))} · {request.requester_email}</strong><p>{request.reason}</p><ReviewRefund request={request} onSaved={saved}/></article>)}{!shifts.some(shift=>shift.status==="pending_approval"&&shift.cashier_user_id!==userId)&&(!canApprove||!refunds.some(request=>request.requested_by!==userId))&&<p className="empty-state">No reviews assigned to you.</p>}</div></div>}<div className="table-wrap"><table><thead><tr><th>Cashier</th><th>Opened</th><th>Status</th><th>Opening float</th><th>Cash variance</th><th>Tenders</th></tr></thead><tbody>{shifts.map(shift=><tr key={shift.shift_id}><td>{shift.cashier_email}</td><td>{new Date(shift.opened_at).toLocaleString("en-NG")}</td><td>{shift.status.replaceAll("_"," ")}</td><td>{money(Number(shift.opening_float_kobo))}</td><td>{shift.variance_kobo===null?"—":money(Number(shift.variance_kobo))}</td><td>{Object.entries(shift.tender_totals??{}).map(([name,total])=><small className="statement-reference" key={name}>{name}: {money(Number(total.net_kobo))}</small>)}</td></tr>)}</tbody></table>{!shifts.length&&<p className="empty-state">No cashier shifts recorded.</p>}</div></section>;
}

function ShiftSummary({shift}:{shift:Shift}) {
  return <div className="statement-summary"><span><b>Opened</b>{new Date(shift.opened_at).toLocaleString("en-NG")}</span><span><b>Float</b>{money(Number(shift.opening_float_kobo))}</span>{Object.entries(shift.tender_totals??{}).map(([name,total])=><span key={name}><b>{name}</b>{money(Number(total.net_kobo))}</span>)}</div>;
}
