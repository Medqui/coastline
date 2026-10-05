"use client";

import { useActionState, useEffect, useState } from "react";
import { classifyCashFlowAction, type ActionState } from "@/app/actions";
import { createClient } from "@/lib/supabase/client";
import { readWithRetry } from "@/lib/supabase/read-with-retry";

type Balance = { account_code:string; account_name:string; account_type:string; amount_kobo:number };
type Flow = { activity:string; inflow_kobo:number; outflow_kobo:number; net_kobo:number };
type CashSummary = { opening_cash_kobo:number; closing_cash_kobo:number; net_change_kobo:number; unclassified_journals:number; pos_clearing_kobo:number };
type Aging = { folio_id:string; reservation_id:string; guest_name:string; oldest_unpaid_charge:string|null; net_balance_kobo:number; outstanding_kobo:number; credit_kobo:number; age_0_30_kobo:number; age_31_60_kobo:number; age_61_90_kobo:number; age_90_plus_kobo:number; unaged_kobo:number };
type AgingSummary = Omit<Aging,"folio_id"|"reservation_id"|"guest_name"|"oldest_unpaid_charge"|"net_balance_kobo"> & { ledger_kobo:number; folio_net_kobo:number; unassigned_kobo:number; unpaid_folios:number };
type Movement = { journal_id:string; journal_date:string; memo:string; source_type:string; activity:string; amount_kobo:number; classification_reason:string|null };
type Report = { key:string; balances:Balance[]; flows:Flow[]; cash:CashSummary; aging:Aging[]; guest:AgingSummary; movements:Movement[] };
const amount = (value:number) => BigInt(value);
const money = (value:number|bigint) => {
  const n=typeof value==="bigint"?value:amount(value); const a=n<BigInt(0)?-n:n;
  return `${n<BigInt(0)?"−":""}₦${new Intl.NumberFormat("en-NG").format(a/BigInt(100))}.${String(a%BigInt(100)).padStart(2,"0")}`;
};
const total = <T,>(rows:T[],value:(row:T)=>number) => rows.reduce((sum,row)=>sum+amount(value(row)),BigInt(0));
const activityName = (value:string) => ({operating:"Operating",investing:"Investing",financing:"Financing",unclassified:"Needs classification"}[value]??value);

function downloadCsv(name:string,rows:(string|number)[][]) {
  const csv=rows.map(row=>row.map(value=>`"${String(value).replaceAll('"','""')}"`).join(",")).join("\r\n");
  const url=URL.createObjectURL(new Blob(["\uFEFF",csv],{type:"text/csv;charset=utf-8"}));
  const link=document.createElement("a");link.href=url;link.download=name;link.click();URL.revokeObjectURL(url);
}

export function FinancialStatements({propertyId,role,from,to,refresh,onRefresh}:{propertyId:string;role:string;from:string;to:string;refresh:number;onRefresh:()=>void}) {
  const key=`${propertyId}:${from}:${to}:${refresh}`;
  const [report,setReport]=useState<Report>(); const [error,setError]=useState("");const[loading,setLoading]=useState(true);
  const canClassify=["owner","accountant"].includes(role);
  useEffect(()=>{
    let active=true;setLoading(true);setError("");
    if(!from||!to||to<from){setLoading(false);setError("Choose a valid report period above.");return;}
    const db=createClient();
    Promise.all([
      readWithRetry(()=>db.rpc("get_balance_sheet",{p_property_id:propertyId,p_as_of:to})),
      readWithRetry(()=>db.rpc("get_cash_flow",{p_property_id:propertyId,p_from:from,p_to:to})),
      readWithRetry(()=>db.rpc("get_cash_flow_summary",{p_property_id:propertyId,p_from:from,p_to:to})),
      readWithRetry(()=>db.rpc("get_guest_receivables_aging",{p_property_id:propertyId,p_as_of:to}).limit(100)),
      readWithRetry(()=>db.rpc("get_guest_receivables_summary",{p_property_id:propertyId,p_as_of:to})),
      readWithRetry(()=>db.rpc("get_cash_flow_journals",{p_property_id:propertyId,p_from:from,p_to:to}).limit(100)),
    ]).then(([balance,flow,cash,aging,guest,movements])=>{
      if(!active)return;setLoading(false);
      if([balance,flow,cash,aging,guest,movements].some(result=>result.error)||!cash.data?.[0]||!guest.data?.[0]){
        setError("Financial statements could not be loaded. Try Refresh reports; if this continues, contact the hotel administrator.");return;
      }
      const rows=[...(balance.data??[]),...(flow.data??[]),...(cash.data??[]),...(aging.data??[]),...(guest.data??[]),...(movements.data??[])];
      if(rows.some(row=>Object.entries(row).some(([field,value])=>field.endsWith("_kobo")&&(typeof value!=="number"||!Number.isSafeInteger(value))))){
        setError("A report amount cannot be displayed safely. Contact the hotel administrator for an exact ledger export.");return;
      }
      setReport({key,balances:(balance.data??[])as Balance[],flows:(flow.data??[])as Flow[],cash:cash.data[0]as CashSummary,aging:(aging.data??[])as Aging[],guest:guest.data[0]as AgingSummary,movements:(movements.data??[])as Movement[]});
    },()=>{if(active){setLoading(false);setError("Financial statements are temporarily unavailable. Try Refresh reports.");}});
    return()=>{active=false;};
  },[propertyId,from,to,refresh,key]);
  const data=report?.key===key&&!loading&&!error?report:undefined;
  const assets=data?total(data.balances.filter(row=>row.account_type==="asset"),row=>row.amount_kobo):BigInt(0);
  const liabilities=data?total(data.balances.filter(row=>row.account_type==="liability"),row=>row.amount_kobo):BigInt(0);
  const equity=data?total(data.balances.filter(row=>row.account_type==="equity"),row=>row.amount_kobo):BigInt(0);
  const flowNet=data?total(data.flows,row=>row.net_kobo):BigInt(0);
  return <section className="panel financial-statements-panel">
    <div className="panel-heading"><div><strong>Financial position &amp; cash flow</strong><small>Uses the From and To dates above. Balances and guest aging are as of {to}.</small></div></div>
    {loading&&<p className="empty-state" role="status">Loading financial statements…</p>}
    {error&&<p className="form-error" role="alert">{error}</p>}
    {data&&<>
      <div className="content-grid two-col report-tables">
        <div><div className="panel-heading"><h3>Balance sheet</h3><button className="button" onClick={()=>downloadCsv(`balance-sheet-${to}.csv`,[["As of",to],["Account","Type","Amount (NGN)"],...data.balances.map(row=>[row.account_name,row.account_type,money(row.amount_kobo)]),["Assets",money(assets)],["Liabilities and equity",money(liabilities+equity)]])}>Export balance sheet</button></div>
          <div className="table-wrap"><table><thead><tr><th>Account</th><th>Type</th><th>Balance</th></tr></thead><tbody>{["asset","liability","equity"].flatMap(kind=>data.balances.filter(row=>row.account_type===kind)).map(row=><tr key={row.account_code}><td>{row.account_name}</td><td>{row.account_type}</td><td>{money(row.amount_kobo)}</td></tr>)}</tbody><tfoot><tr><th>Total assets</th><th/><th>{money(assets)}</th></tr><tr><th>Liabilities &amp; equity</th><th/><th>{money(liabilities+equity)}</th></tr></tfoot></table></div>
          {assets!==liabilities+equity&&<p className="form-error" role="alert">The balance sheet does not balance. Contact the accountant.</p>}
          <p className="optional">Earnings include posted income and expenses not closed into an equity account. This is the position recorded in these books; opening balances must be posted before they appear here.</p>
        </div>
        <div><div className="panel-heading"><h3>Cash-flow statement</h3><button className="button" onClick={()=>downloadCsv(`cash-flow-${from}-${to}.csv`,[["Period",from,to],["Cash and bank at start",money(data.cash.opening_cash_kobo)],["Activity","Receipts","Payments","Net"],...data.flows.map(row=>[activityName(row.activity),money(row.inflow_kobo),money(row.outflow_kobo),money(row.net_kobo)]),["Net movement",money(flowNet)],["Cash and bank at end",money(data.cash.closing_cash_kobo)],["Card clearing (excluded)",money(data.cash.pos_clearing_kobo)]])}>Export cash flow</button></div>
          <p>Cash and bank at start: <strong>{money(data.cash.opening_cash_kobo)}</strong></p>
          <div className="table-wrap"><table><thead><tr><th>Activity</th><th>Receipts</th><th>Payments</th><th>Net</th></tr></thead><tbody>{["operating","investing","financing","unclassified"].map(kind=>data.flows.find(row=>row.activity===kind)).filter((row):row is Flow=>Boolean(row)).map(row=><tr key={row.activity}><td>{activityName(row.activity)}</td><td>{money(row.inflow_kobo)}</td><td>{money(row.outflow_kobo)}</td><td>{money(row.net_kobo)}</td></tr>)}</tbody><tfoot><tr><th>Net movement</th><th colSpan={2}/><th>{money(flowNet)}</th></tr></tfoot></table></div>
          <p>Cash and bank at end: <strong>{money(data.cash.closing_cash_kobo)}</strong></p>
          {flowNet!==amount(data.cash.net_change_kobo)&&<p className="form-error" role="alert">Cash movements do not reconcile to the closing balance. Contact the accountant.</p>}
          {data.cash.unclassified_journals>0&&<p className="form-error" role="alert">{data.cash.unclassified_journals} cash entries need classification. The full movement is included above; complete the classifications before using the statement for reporting.</p>}
          <p className="optional">Cash and bank only. Card clearing of {money(data.cash.pos_clearing_kobo)} is excluded until it reaches a bank account. Unpaid bills and deposit applications do not move cash. Transfers between cash and bank have no net effect.</p>
        </div>
      </div>
      <div className="report-tables"><div className="panel-heading"><h3>Guest receivables aging</h3><button className="button" onClick={()=>downloadCsv(`guest-aging-${to}.csv`,[["As of",to],["Age basis","Days since posted charge; oldest charges paid first"],["Ledger receivables",money(data.guest.ledger_kobo)],["Unassigned ledger balance",money(data.guest.unassigned_kobo)],["Outstanding",money(data.guest.outstanding_kobo)],["Credit balances",money(data.guest.credit_kobo)],["0–30 days",money(data.guest.age_0_30_kobo)],["31–60 days",money(data.guest.age_31_60_kobo)],["61–90 days",money(data.guest.age_61_90_kobo)],["Over 90 days",money(data.guest.age_90_plus_kobo)],["Unaged",money(data.guest.unaged_kobo)]])}>Export aging summary</button></div>
        <div className="supplier-summary">{[["Outstanding",data.guest.outstanding_kobo],["0–30 days",data.guest.age_0_30_kobo],["31–60 days",data.guest.age_31_60_kobo],["61–90 days",data.guest.age_61_90_kobo],["Over 90 days",data.guest.age_90_plus_kobo],["Credit balances",data.guest.credit_kobo]].map(([label,value])=><div key={String(label)}><span>{String(label)}</span><strong>{money(Number(value))}</strong></div>)}</div>
        <p className="optional">Age is days since each posted charge, with payments applied to oldest charges first for this report. It is not days past a contractual due date. Advances are excluded until applied. Totals include all folios; the list shows the first 100 with a nonzero posted balance.</p>
        {(Number(data.guest.unassigned_kobo)!==0||Number(data.guest.unaged_kobo)!==0)&&<p className="form-error" role="alert">Accountant review required: {money(data.guest.unassigned_kobo)} in the receivables ledger has no unique folio mapping; {money(data.guest.unaged_kobo)} in folios has no charge age. Neither amount is hidden from the controls below.</p>}
        <p>Receivables ledger: <strong>{money(data.guest.ledger_kobo)}</strong> · Net folios: <strong>{money(data.guest.folio_net_kobo)}</strong> · Unassigned: <strong>{money(data.guest.unassigned_kobo)}</strong></p>
        <div className="table-wrap"><table><thead><tr><th>Guest</th><th>Oldest unpaid charge</th><th>0–30 days</th><th>31–60</th><th>61–90</th><th>Over 90</th><th>Unaged</th><th>Owed</th><th>Credit</th></tr></thead><tbody>{data.aging.map(row=><tr key={row.folio_id}><td>{row.guest_name}<small>Stay {row.reservation_id.slice(0,8)}</small></td><td>{row.oldest_unpaid_charge??"—"}</td><td>{money(row.age_0_30_kobo)}</td><td>{money(row.age_31_60_kobo)}</td><td>{money(row.age_61_90_kobo)}</td><td>{money(row.age_90_plus_kobo)}</td><td>{money(row.unaged_kobo)}</td><td>{money(row.outstanding_kobo)}</td><td>{money(row.credit_kobo)}</td></tr>)}</tbody></table>{!data.aging.length&&<div className="empty-state">No posted guest balances through this date.</div>}</div>
      </div>
      <details className="rate-period-list"><summary>Cash movements &amp; classifications · latest 100</summary>
        <p className="optional">Classification updates are audited and apply to reports for the entry’s posting date. They do not change the original journal or cash amount.</p>
        {data.movements.map(row=><article className="maintenance-order" key={row.journal_id}><strong>{row.journal_date} · {row.memo}</strong><p>{money(row.amount_kobo)} · {activityName(row.activity)}{row.classification_reason&&` · ${row.classification_reason}`}</p>{canClassify&&!['folio_payment','guest_deposit','payment_refund','expense','supplier_payment','supplier_payment_reversal'].includes(row.source_type)&&<details><summary>{row.activity==="unclassified"?"Classify movement":"Revise classification"}</summary><Classification key={`${row.journal_id}:${row.activity}:${refresh}`} journalId={row.journal_id} saved={onRefresh}/></details>}</article>)}
        {!data.movements.length&&<p>No cash or bank movements in this period.</p>}
        {!canClassify&&<p className="optional">An owner or accountant can classify entries that need review.</p>}
      </details>
    </>}
  </section>;
}

function Classification({journalId,saved}:{journalId:string;saved:()=>void}) {
  const[state,action,pending]=useActionState(classifyCashFlowAction,{} as ActionState);const[key,setKey]=useState("");
  useEffect(()=>{setKey(crypto.randomUUID());},[]);useEffect(()=>{if(state.success)saved();},[state.success,saved]);
  return <form action={action} className="reservation-form"><input type="hidden" name="journal_id" value={journalId}/><input type="hidden" name="idempotency_key" value={key}/>
    <label>Cash-flow activity<select name="activity" required><option value="operating">Operating</option><option value="investing">Investing</option><option value="financing">Financing</option></select></label>
    <label>Classification reason<input name="reason" required minLength={5} maxLength={500}/></label>
    {state.error&&<p className="form-error" role="alert">{state.error}</p>}<button className="button" disabled={pending||!key}>{pending?"Saving…":"Save classification"}</button>
  </form>;
}
