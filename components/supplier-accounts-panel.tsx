"use client";

import { useActionState, useCallback, useEffect, useState } from "react";
import { attachSupplierBillReceiptAction, saveSupplierAction, postSupplierBillAction, paySupplierBillAction, reverseSupplierPaymentAction, voidSupplierBillAction, type ActionState } from "@/app/actions";
import { createClient } from "@/lib/supabase/client";
import { readWithRetry } from "@/lib/supabase/read-with-retry";
import type { DepartmentOption, PaymentMethodOption } from "@/components/hotel-dashboard";

type Supplier = { id: string; name: string; phone: string | null; email: string | null; address: string | null; active: boolean };
type Bill = { bill_id: string; supplier_name: string; bill_number: string; invoice_date: string; posting_date: string; due_date: string;
  description: string; amount_kobo: number; paid_kobo: number; outstanding_kobo: number; status: string; receipt_path: string | null };
type Payment = { payment_id: string; bill_number: string; supplier_name: string; payment_date: string; amount_kobo: number;
  method_name: string; reference: string | null; status: string; reversal_date: string | null; reversal_reason: string | null };
type Summary = { outstanding_kobo: number; current_kobo: number; overdue_1_30_kobo: number; overdue_31_60_kobo: number;
  overdue_61_90_kobo: number; overdue_90_plus_kobo: number; unpaid_bills: number };
const categories = [{ code:"5000",name:"Operating expenses" },{code:"5010",name:"Utilities"},{code:"5020",name:"Repairs and maintenance"},
  {code:"5030",name:"Staff costs"},{code:"5040",name:"Guest and housekeeping supplies"},{code:"5050",name:"Food and beverage"},
  {code:"5060",name:"Transport and logistics"},{code:"5070",name:"Sales and marketing"},{code:"5090",name:"Other operating expenses"}];
const money = (kobo: number) => new Intl.NumberFormat("en-NG",{style:"currency",currency:"NGN"}).format(Number(kobo)/100);
const today = () => new Date().toLocaleDateString("en-CA",{timeZone:"Africa/Lagos"});

function SupplierForm({ propertyId, supplier, saved }: { propertyId: string; supplier?: Supplier; saved: () => void }) {
  const [state,action,pending] = useActionState(saveSupplierAction,{} as ActionState);
  useEffect(() => { if(state.success) saved(); },[state.success,saved]);
  return <form action={action} className="reservation-form"><input type="hidden" name="property_id" value={propertyId}/><input type="hidden" name="supplier_id" value={supplier?.id ?? ""}/>
    <label>Supplier name<input name="name" required minLength={2} maxLength={120} defaultValue={supplier?.name}/></label>
    <div className="reservation-form-row"><label>Phone<input name="phone" type="tel" maxLength={80} defaultValue={supplier?.phone ?? ""}/></label><label>Email<input name="email" type="email" maxLength={254} defaultValue={supplier?.email ?? ""}/></label></div>
    <label>Address<textarea name="address" rows={2} maxLength={500} defaultValue={supplier?.address ?? ""}/></label>
    <label><span><input name="active" type="checkbox" defaultChecked={supplier?.active ?? true}/> Active supplier</span></label>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}<button className="button button-primary" disabled={pending}>{pending?"Saving…":supplier?"Save supplier":"Add supplier"}</button></form>;
}
function BillForm({propertyId,suppliers,departments,saved,another}:{propertyId:string;suppliers:Supplier[];departments:DepartmentOption[];saved:(notice?:string)=>void;another:()=>void}) {
  const [state,action,pending] = useActionState(postSupplierBillAction,{} as ActionState);
  const [key,setKey] = useState("");useEffect(()=>{setKey(crypto.randomUUID());},[]);
  useEffect(()=>{if(state.success)saved(state.notice);},[state.success,state.notice,saved]);
  if(state.success)return <div className="folio-success" role="status">Supplier bill recorded. {state.notice && <p className="form-error">{state.notice}</p>}<button className="button" onClick={another}>Record another bill</button></div>;
  return <form action={action} className="reservation-form"><input type="hidden" name="property_id" value={propertyId}/><input type="hidden" name="idempotency_key" value={key}/>
    <label>Supplier<select name="supplier_id" required>{suppliers.filter(supplier=>supplier.active).map(supplier=><option key={supplier.id} value={supplier.id}>{supplier.name}</option>)}</select></label>
    <label>Invoice number<input name="bill_number" required maxLength={80}/></label>
    <div className="reservation-form-row"><label>Invoice date<input name="invoice_date" type="date" required max={today()} defaultValue={today()}/></label><label>Accounting date<input name="posting_date" type="date" required max={today()} defaultValue={today()}/></label></div>
    <label>Payment due date<input name="due_date" type="date" required defaultValue={today()}/></label>
    <label>Description<input name="description" required minLength={2} maxLength={500}/></label>
    <div className="reservation-form-row"><label>Category<select name="account_code">{categories.map(category=><option key={category.code} value={category.code}>{category.name}</option>)}</select></label><label>Department<select name="department_id" required defaultValue={departments.find(department=>department.code==="administration")?.id}>{departments.map(department=><option key={department.id} value={department.id}>{department.name}</option>)}</select></label></div>
    <label>Invoice amount (₦)<input name="amount" type="number" min="0.01" step="0.01" required/></label>
    <label>Invoice / receipt <span className="optional">Optional · JPG, PNG, PDF · up to 10 MB</span><input name="receipt_file" type="file" accept="image/jpeg,image/png,application/pdf"/></label>
    <p className="optional">The accounting date determines the report period. Record payment separately when the supplier is paid.</p>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}<button className="button button-primary" disabled={pending||!key||!departments.length||!suppliers.some(supplier=>supplier.active)}>{pending?"Posting…":"Record unpaid bill"}</button></form>;
}
function PayBill({bill,methods,saved}:{bill:Bill;methods:PaymentMethodOption[];saved:()=>void}) {
  const [state,action,pending]=useActionState(paySupplierBillAction,{} as ActionState);const[key,setKey]=useState("");useEffect(()=>{setKey(crypto.randomUUID());},[]);
  useEffect(()=>{if(state.success)saved();},[state.success,saved]);
  return <form action={action} className="reservation-form"><input type="hidden" name="bill_id" value={bill.bill_id}/><input type="hidden" name="idempotency_key" value={key}/>
    <div className="reservation-form-row"><label>Amount paid (₦)<input name="amount" type="number" min="0.01" step="0.01" max={(Number(bill.outstanding_kobo)/100).toFixed(2)} required/></label><label>Paid with<select name="payment_method_id" required>{methods.map(method=><option key={method.id} value={method.id}>{method.name}</option>)}</select></label></div>
    <label>Payment date<input name="payment_date" type="date" min={bill.posting_date} max={today()} defaultValue={today()} required/></label><label>Reference<input name="reference" maxLength={200}/></label>
    {state.error&&<p className="form-error" role="alert">{state.error}</p>}<button className="button button-primary" disabled={pending||!key||!methods.length}>{pending?"Saving…":"Record supplier payment"}</button></form>;
}
function BillReceipt({billId,saved}:{billId:string;saved:()=>void}) {
  const[state,action,pending]=useActionState(attachSupplierBillReceiptAction,{} as ActionState);
  useEffect(()=>{if(state.success)saved();},[state.success,saved]);
  return <form action={action} className="reservation-form"><input type="hidden" name="bill_id" value={billId}/>
    <label>Invoice receipt<input name="receipt_file" type="file" accept="image/jpeg,image/png,application/pdf" required/></label>
    <p className="optional">JPG, PNG or PDF · up to 10 MB. This updates the attachment on the existing bill.</p>
    {state.error&&<p className="form-error" role="alert">{state.error}</p>}
    <button className="button" disabled={pending}>{pending?"Saving…":"Save receipt"}</button></form>;
}
function Correction({id,kind,minDate,saved}:{id:string;kind:"bill"|"payment";minDate:string;saved:()=>void}) {
  const [state,action,pending]=useActionState(kind==="bill"?voidSupplierBillAction:reverseSupplierPaymentAction,{} as ActionState);
  useEffect(()=>{if(state.success)saved();},[state.success,saved]);
  return <form action={action} className="reservation-form"><input type="hidden" name={kind==="bill"?"bill_id":"payment_id"} value={id}/>
    <label>Correction date<input name="date" type="date" min={minDate} max={today()} defaultValue={today()} required/></label><label>Reason<input name="reason" required minLength={5} maxLength={500}/></label>
    <p className="optional">This records a linked reversal in the books. Confirm the actual supplier and bank records before correcting a payment.</p>
    {state.error&&<p className="form-error" role="alert">{state.error}</p>}<button className="button" disabled={pending}>{pending?"Saving…":kind==="bill"?"Void unpaid bill":"Reverse payment record"}</button></form>;
}

export function SupplierAccountsPanel({propertyId,role,methods,departments}:{propertyId:string;role:string;methods:PaymentMethodOption[];departments:DepartmentOption[]}) {
  const [asOf,setAsOf]=useState(today);const [suppliers,setSuppliers]=useState<Supplier[]>([]);const[bills,setBills]=useState<Bill[]>([]);const[payments,setPayments]=useState<Payment[]>([]);const[summary,setSummary]=useState<Summary>();
  const[billDraft,setBillDraft]=useState(0);const[dataAsOf,setDataAsOf]=useState("");const[revision,setRevision]=useState(0);const[loading,setLoading]=useState(true);const[error,setError]=useState("");const[notice,setNotice]=useState("");const[editing,setEditing]=useState<Supplier>();const[receiptError,setReceiptError]=useState("");
  const canPay=["owner","accountant"].includes(role);const live=asOf===today();
  const saved=useCallback((receiptNotice?:string)=>{setRevision(value=>value+1);setEditing(undefined);setNotice(receiptNotice || "Supplier accounts saved. Refresh historical reports to include any backdated entry.");},[]);
  useEffect(()=>{
    let active=true;setLoading(true);setError("");const supabase=createClient();
    Promise.all([
      readWithRetry(() => supabase.from("suppliers").select("id,name,phone,email,address,active").eq("property_id",propertyId).order("name")),
      readWithRetry(() => supabase.rpc("get_supplier_bill_balances",{p_property_id:propertyId,p_as_of:asOf}).limit(100)),
      readWithRetry(() => supabase.rpc("get_supplier_payment_history",{p_property_id:propertyId,p_as_of:asOf}).limit(100)),
      readWithRetry(() => supabase.rpc("get_supplier_payables_summary",{p_property_id:propertyId,p_as_of:asOf})),
    ]).then(([supplierResult,billResult,paymentResult,summaryResult])=>{
      if(!active)return;setLoading(false);
      if([supplierResult,billResult,paymentResult,summaryResult].some(result=>result.error)){setError("Supplier accounts could not be loaded. Try Refresh; if this continues, contact the hotel administrator.");return;}
      setSuppliers((supplierResult.data??[])as Supplier[]);setBills((billResult.data??[])as Bill[]);setPayments((paymentResult.data??[])as Payment[]);setSummary(summaryResult.data?.[0]as Summary|undefined);setDataAsOf(asOf);
    },()=>{if(active){setLoading(false);setError("Supplier accounts could not be loaded. Try refreshing.");}});return()=>{active=false;};
  },[propertyId,asOf,revision]);
  const openReceipt=async(path:string)=>{
    setReceiptError("");
    try {
      const{data,error:requestError}=await createClient().storage.from("expense-receipts").createSignedUrl(path,60);
      if(requestError||!data){setReceiptError("The invoice receipt could not be opened.");return;}
      window.open(data.signedUrl,"_blank","noopener,noreferrer");
    } catch {setReceiptError("The invoice receipt could not be opened. Try again.");}
  };
  return <section className="panel maintenance-panel supplier-panel"><div className="panel-heading"><div><h2>Supplier bills &amp; payments</h2><p>Record invoices once, track what is owed, and settle them separately.</p></div><button className="button" onClick={()=>setRevision(value=>value+1)}>Refresh</button></div>
    <label className="date-filter">Balances as of<input type="date" max={today()} value={asOf} onChange={event=>event.target.value&&setAsOf(event.target.value)}/></label>
    {notice&&<p className="folio-success" role="status">{notice}</p>}{receiptError&&<p className="form-error" role="alert">{receiptError}</p>}
    {loading&&dataAsOf===asOf&&<p role="status">Updating supplier accounts…</p>}
    {loading&&dataAsOf!==asOf?<p role="status">Loading supplier accounts…</p>:error?<p className="form-error" role="alert">{error}</p>:<>
      {summary&&<div className="supplier-summary">{[["Outstanding",summary.outstanding_kobo],["Not overdue",summary.current_kobo],["1–30 days overdue",summary.overdue_1_30_kobo],["31–60 days overdue",summary.overdue_31_60_kobo],["61–90 days overdue",summary.overdue_61_90_kobo],["Over 90 days overdue",summary.overdue_90_plus_kobo]].map(([label,value])=><div key={String(label)}><span>{label}</span><strong>{money(Number(value))}</strong></div>)}<p>{Number(summary.unpaid_bills)} unpaid bills · totals include all records; the lists show the latest 100.</p></div>}
      {live?<div className="maintenance-layout"><div><h3>{editing?"Edit supplier":"Add supplier"}</h3><SupplierForm key={`supplier:${editing?.id??"new"}:${revision}:${propertyId}`} propertyId={propertyId} supplier={editing} saved={saved}/>{editing&&<button className="text-button" onClick={()=>setEditing(undefined)}>Cancel editing</button>}</div><div><h3>Record a supplier invoice</h3><BillForm key={`bill:${propertyId}:${billDraft}`} propertyId={propertyId} suppliers={suppliers} departments={departments} saved={saved} another={()=>setBillDraft(value=>value+1)}/></div></div>:<p className="optional">Historical view. Return to today to enter or correct supplier records.</p>}
      <details className="rate-period-list"><summary>Supplier directory · {suppliers.length} suppliers</summary>{suppliers.map(supplier=><div className="maintenance-order" key={supplier.id}><strong>{supplier.name} · {supplier.active?"Active":"Inactive"}</strong><p>{supplier.phone} {supplier.email}</p>{live&&<button className="button" onClick={()=>setEditing(supplier)}>Edit details</button>}</div>)}</details>
      <div className="rate-period-list"><h3>Latest bills as of {asOf}</h3>{bills.length?bills.map(bill=><article className="maintenance-order" key={`${bill.bill_id}:${bill.status}:${bill.outstanding_kobo}:${revision}`}><strong>{bill.supplier_name} · {bill.bill_number}</strong><p>{bill.description} · Invoice {bill.invoice_date} · Accounting date {bill.posting_date} · Due {bill.due_date}</p><p>Total {money(bill.amount_kobo)} · Paid {money(bill.paid_kobo)} · Owed <strong>{money(bill.outstanding_kobo)}</strong> · {bill.status==="void"?"Void":Number(bill.outstanding_kobo)===0?"Settled":"Unpaid"}</p>
        {bill.receipt_path&&<button className="text-button" onClick={()=>openReceipt(bill.receipt_path!)}>View invoice receipt</button>}
        {live&&<details><summary>{bill.receipt_path?"Replace invoice receipt":"Attach invoice receipt"}</summary><BillReceipt billId={bill.bill_id} saved={saved}/></details>}
        {live&&canPay&&bill.status==="posted"&&Number(bill.outstanding_kobo)>0&&<details><summary>Record payment</summary><PayBill bill={bill} methods={methods} saved={saved}/></details>}
        {live&&canPay&&bill.status==="posted"&&Number(bill.paid_kobo)===0&&<details><summary>Correct / void bill</summary><Correction id={bill.bill_id} kind="bill" minDate={bill.posting_date} saved={saved}/></details>}
      </article>):<p>No bills posted by this date.</p>}</div>
      <div className="rate-period-list"><h3>Latest supplier payments as of {asOf}</h3>{payments.length?payments.map(payment=><article className="maintenance-order" key={`${payment.payment_id}:${payment.status}:${revision}`}><strong>{payment.supplier_name} · {payment.bill_number}</strong><p>{payment.payment_date} · {money(payment.amount_kobo)} · {payment.method_name} · {payment.status} {payment.reference&&`· ${payment.reference}`}</p>{payment.reversal_date&&<p>Reversed {payment.reversal_date}: {payment.reversal_reason}</p>}{live&&canPay&&payment.status==="posted"&&<details><summary>Correct payment record</summary><Correction id={payment.payment_id} kind="payment" minDate={payment.payment_date} saved={saved}/></details>}</article>):<p>No supplier payments recorded by this date.</p>}</div>
    </>}
  </section>;
}
