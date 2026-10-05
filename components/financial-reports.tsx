"use client";
import { useCallback, useEffect, useState } from "react";
import { ArrowDownToLine, LoaderCircle } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { readWithRetry } from "@/lib/supabase/read-with-retry";
import { completeBankReconciliationAction, createBankReconciliationAction, type ActionState } from "@/app/actions";
import { useActionState } from "react";
import { FinancialStatements } from "@/components/financial-statements";
import { BankStatementReconciliation } from "@/components/bank-statement-reconciliation";
import type { PaymentMethodOption } from "@/components/hotel-dashboard";

type AccountRow = { account_code: string; account_name: string; account_type: string; amount_kobo?: number; debit_balance_kobo?: number; credit_balance_kobo?: number };
type DepartmentRow = { department_code: string; department_name: string; revenue_kobo: number; expense_kobo: number; net_income_kobo: number };
type Reconciliation = { id: string; period_from: string; period_to: string; statement_balance_kobo: number; book_balance_kobo: number; difference_kobo: number; status: string; payment_method_id: string; matching_required: boolean };
const money = (value: number) => `₦${new Intl.NumberFormat("en-NG", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value / 100)}`;
export function FinancialReports({ propertyId, methods, from: initialFrom, role }: { propertyId: string; methods: PaymentMethodOption[]; from: string; role: string }) {
  const today = new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Lagos" });
  const [from, setFrom] = useState(initialFrom); const [to, setTo] = useState(today);
  const [departmentPnl,setDepartmentPnl]=useState<DepartmentRow[]>([]);
  const [pnl, setPnl] = useState<AccountRow[]>([]); const [trial, setTrial] = useState<AccountRow[]>([]);
  const [reconciliations, setReconciliations] = useState<Reconciliation[]>([]); const [reconciliationError, setReconciliationError] = useState(""); const [error, setError] = useState(""); const [loading, setLoading] = useState(false); const [refresh, setRefresh] = useState(0);
  const [selectedReconciliation,setSelectedReconciliation]=useState<string|null>(null);
  useEffect(() => {
    let active = true;
    setReconciliations([]); setReconciliationError("");
    if (!from || !to || to < from) { setError("Choose a valid report period."); setPnl([]);setTrial([]);setDepartmentPnl([]);setLoading(false); return; }
    setLoading(true); setError(""); const supabase = createClient();
    Promise.all([
      readWithRetry(() => supabase.rpc("get_profit_and_loss", { p_property_id: propertyId, p_from: from, p_to: to })),
      readWithRetry(() => supabase.rpc("get_trial_balance", { p_property_id: propertyId, p_as_of: to })),
      readWithRetry(() => supabase.rpc("get_department_profit_and_loss",{p_property_id:propertyId,p_from:from,p_to:to})),
      readWithRetry(() => supabase.from("bank_reconciliations").select("id,period_from,period_to,statement_balance_kobo,book_balance_kobo,difference_kobo,status,payment_method_id,matching_required").eq("property_id",propertyId).order("created_at",{ascending:false}).limit(12)),
    ]).then(([pnlResult, trialResult, departmentResult, recResult]) => {
      if (!active) return;
      if (pnlResult.error || trialResult.error || departmentResult.error) {setError("Could not load the reports. Try Refresh reports; if this continues, contact the hotel administrator.");setPnl([]);setTrial([]);setDepartmentPnl([]);}
      else { setDepartmentPnl((departmentResult.data??[])as DepartmentRow[]);setPnl((pnlResult.data ?? []) as AccountRow[]); setTrial((trialResult.data ?? []) as AccountRow[]); }
      if (recResult.error) setReconciliationError("Reconciliations could not be loaded. Try Refresh reports.");
      else setReconciliations((recResult.data ?? []) as Reconciliation[]);
      setLoading(false);
    }).catch(() => { if (active) { setError("Reports are temporarily unavailable. Try Refresh reports."); setReconciliationError("Reconciliations could not be loaded. Try Refresh reports."); setLoading(false); } });
    return () => { active = false; };
  }, [propertyId, from, to, refresh]);
  const revenue = pnl.filter(row => row.account_type === "revenue").reduce((sum,row) => sum + Number(row.amount_kobo ?? 0),0);
  const expenses = pnl.filter(row => row.account_type === "expense").reduce((sum,row) => sum + Number(row.amount_kobo ?? 0),0);
  const canReconcile = ["owner","accountant"].includes(role);
  const refreshReconciliations = useCallback(() => setRefresh(value => value + 1), []);
  const exportCsv = () => {
    const data = [["Profit and loss",from,to], ["Account","Type","Amount"], ...pnl.map(row => [row.account_name,row.account_type,money(Number(row.amount_kobo ?? 0))]), ["Net income","net",money(revenue-expenses)]];
    const csv = data.map(row => row.map(value => `"${String(value).replaceAll('"','""')}"`).join(",")).join("\r\n");
    const url=URL.createObjectURL(new Blob(["\uFEFF",csv],{type:"text/csv;charset=utf-8"})); const a=document.createElement("a"); a.href=url; a.download=`profit-and-loss-${from}-${to}.csv`; a.click(); URL.revokeObjectURL(url);
  };
  return <div className="financial-reports"><section className="panel"><div className="panel-heading"><div><strong>Historical reports</strong><small>Income statement uses posted journal date; trial balance is cumulative through the end date.</small></div><button className="button" onClick={exportCsv} disabled={loading||Boolean(error)}><ArrowDownToLine size={14}/>Export P&amp;L</button></div><div className="page-tools"><button className="button" onClick={()=>setRefresh(value=>value+1)}>Refresh reports</button><label className="date-filter">From<input type="date" value={from} onChange={event=>setFrom(event.target.value)}/></label><label className="date-filter">To<input type="date" value={to} onChange={event=>setTo(event.target.value)}/></label>{loading && <span className="report-loading"><LoaderCircle size={14} className="spin"/>Updating</span>}</div>{error && <p className="form-error report-error">{error}</p>}
    {!loading&&!error&&<><div className="content-grid two-col report-tables"><div><h3>Profit and loss</h3><div className="table-wrap"><table><thead><tr><th>Account</th><th>Type</th><th>Amount</th></tr></thead><tbody>{pnl.map(row=><tr key={`${row.account_code}-${row.account_type}`}><td>{row.account_name}</td><td>{row.account_type}</td><td className="tabular">{money(Number(row.amount_kobo??0))}</td></tr>)}</tbody><tfoot><tr><th>Net income</th><th/><th className="tabular">{money(revenue-expenses)}</th></tr></tfoot></table>{!pnl.length && !loading && <div className="empty-state">No posted income or expense in this period.</div>}</div></div>
      <div><h3>Trial balance as of {to}</h3><div className="table-wrap"><table><thead><tr><th>Account</th><th>Debit</th><th>Credit</th></tr></thead><tbody>{trial.map(row=><tr key={row.account_code}><td>{row.account_code} · {row.account_name}</td><td className="tabular">{Number(row.debit_balance_kobo)?money(Number(row.debit_balance_kobo)):"—"}</td><td className="tabular">{Number(row.credit_balance_kobo)?money(Number(row.credit_balance_kobo)):"—"}</td></tr>)}</tbody><tfoot><tr><th>Totals</th><th>{money(trial.reduce((sum,row)=>sum+Number(row.debit_balance_kobo??0),0))}</th><th>{money(trial.reduce((sum,row)=>sum+Number(row.credit_balance_kobo??0),0))}</th></tr></tfoot></table>{!trial.length && !loading && <div className="empty-state">No posted journals through this date.</div>}</div></div></div><div className="report-tables"><h3>Income and expenses by department</h3><div className="table-wrap"><table><thead><tr><th>Department</th><th>Revenue</th><th>Expenses</th><th>Net income</th></tr></thead><tbody>{departmentPnl.map(row=><tr key={row.department_code}><td>{row.department_name}</td><td>{money(Number(row.revenue_kobo))}</td><td>{money(Number(row.expense_kobo))}</td><td>{money(Number(row.net_income_kobo))}</td></tr>)}</tbody><tfoot><tr><th>Total</th><th>{money(departmentPnl.reduce((sum,row)=>sum+Number(row.revenue_kobo),0))}</th><th>{money(departmentPnl.reduce((sum,row)=>sum+Number(row.expense_kobo),0))}</th><th>{money(departmentPnl.reduce((sum,row)=>sum+Number(row.net_income_kobo),0))}</th></tr></tfoot></table></div><p className="optional">Older entries without a department use their recorded source: room nights, guest services or administration. Other historical entries are shown as unallocated.</p></div></>}</section>
    <FinancialStatements propertyId={propertyId} role={role} from={from} to={to} refresh={refresh} onRefresh={refreshReconciliations}/>
    <section className="panel reconciliation-panel"><div className="panel-heading"><div><strong>Cash and bank reconciliation</strong><small>Compare the statement closing balance with the ledger balance for a payment account.</small></div></div>{canReconcile ? <ReconciliationForm propertyId={propertyId} methods={methods} onCreated={refreshReconciliations}/> : <p className="empty-state">An owner or accountant can create and complete reconciliations.</p>}
      {reconciliationError&&<p className="form-error" role="alert">{reconciliationError}</p>}<div className="table-wrap"><table><thead><tr><th>Account</th><th>Period</th><th>Statement</th><th>Ledger</th><th>Difference</th><th>Status</th><th/></tr></thead><tbody>{reconciliations.map(row=><tr key={row.id}><td>{methods.find(method=>method.id===row.payment_method_id)?.name??"Account"}</td><td>{row.period_from} – {row.period_to}</td><td>{money(Number(row.statement_balance_kobo))}</td><td>{money(Number(row.book_balance_kobo))}</td><td>{money(Number(row.difference_kobo))}</td><td>{row.status}{row.matching_required&&<small className="statement-reference">Transaction matching</small>}</td><td><div className="inline-action"><button className="text-button" onClick={()=>setSelectedReconciliation(value=>value===row.id?null:row.id)}>{selectedReconciliation===row.id?"Hide statement":"Statement"}</button>{row.status==="open"&&Number(row.difference_kobo)===0&&canReconcile&&<CompleteReconciliation id={row.id} onComplete={refreshReconciliations}/>}</div></td></tr>)}</tbody></table>{!loading&&!reconciliationError&&!reconciliations.length&&<div className="empty-state">No reconciliations started yet.</div>}</div>
      {selectedReconciliation&&reconciliations.some(row=>row.id===selectedReconciliation)&&<BankStatementReconciliation reconciliationId={selectedReconciliation} status={reconciliations.find(row=>row.id===selectedReconciliation)!.status} role={role} onChanged={refreshReconciliations}/>} 
    </section></div>;
}
function ReconciliationForm({propertyId,methods,onCreated}:{propertyId:string;methods:PaymentMethodOption[];onCreated:()=>void}) {
  const [state,action,pending]=useActionState(createBankReconciliationAction,{} as ActionState);
  useEffect(()=>{if(state.success) onCreated();},[state.success,onCreated]);
  return <form action={action} className="reconciliation-form"><input type="hidden" name="property_id" value={propertyId}/><label>Account<select name="payment_method_id" required>{methods.map(method=><option value={method.id} key={method.id}>{method.name}</option>)}</select></label><label>From<input type="date" name="period_from" required/></label><label>To<input type="date" name="period_to" required/></label><label>Opening balance (₦)<input name="opening_balance" type="number" min="0" step="0.01" required/></label><label>Statement closing (₦)<input name="statement_balance" type="number" min="0" step="0.01" required/></label>{state.error&&<span className="form-error">{state.error}</span>}{state.success&&<span className="admin-success">Reconciliation saved. Resolve any difference, then complete it when balances match.</span>}<button className="button button-primary" disabled={pending||!methods.length}>{pending?"Saving…":"Start reconciliation"}</button></form>;
}
function CompleteReconciliation({id,onComplete}:{id:string;onComplete:()=>void}) {
  const [state,action,pending]=useActionState(completeBankReconciliationAction,{} as ActionState);
  useEffect(()=>{if(state.success)onComplete();},[state.success,onComplete]);
  return <form action={action}><input type="hidden" name="reconciliation_id" value={id}/><button className="text-button" disabled={pending}>{state.success?"Completed":pending?"Saving…":"Refresh & complete"}</button>{state.error&&<small className="form-error">{state.error}</small>}</form>;
}
