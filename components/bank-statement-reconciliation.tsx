"use client";

import { useActionState, useCallback, useEffect, useState } from "react";
import { LoaderCircle } from "lucide-react";
import {
  autoMatchBankStatementAction, flagBankStatementExceptionAction, importBankStatementAction,
  matchBankStatementLineAction, voidBankStatementMatchAction, type ActionState,
} from "@/app/actions";
import { createClient } from "@/lib/supabase/client";
import { readWithRetry } from "@/lib/supabase/read-with-retry";

type StatementLine = { line_id:string; transaction_date:string; description:string; reference:string|null; amount_kobo:number; balance_kobo:number|null; status:string; match_id:string|null; matched_journal_id:string|null; exception_reason:string|null };
type LedgerCandidate = { journal_id:string; journal_date:string; memo:string; source_type:string; amount_kobo:number; status:string; matched_statement_line_id:string|null };
const money=(value:number)=>`${value<0?"−":""}₦${new Intl.NumberFormat("en-NG",{minimumFractionDigits:2,maximumFractionDigits:2}).format(Math.abs(value)/100)}`;

export function BankStatementReconciliation({reconciliationId,status,role,onChanged}:{reconciliationId:string;status:string;role:string;onChanged:()=>void}) {
  const [lines,setLines]=useState<StatementLine[]>([]);const[candidates,setCandidates]=useState<LedgerCandidate[]>([]);
  const [loading,setLoading]=useState(true);const[error,setError]=useState("");const[revision,setRevision]=useState(0);
  const canEdit=status==="open"&&["owner","accountant"].includes(role);
  const refresh=useCallback(()=>{setRevision(value=>value+1);onChanged();},[onChanged]);
  useEffect(()=>{
    let active=true;setLoading(true);setError("");const db=createClient();
    Promise.all([
      readWithRetry(()=>db.rpc("get_bank_statement_lines",{p_reconciliation_id:reconciliationId})),
      readWithRetry(()=>db.rpc("get_bank_ledger_candidates",{p_reconciliation_id:reconciliationId})),
    ]).then(([statement,ledger])=>{if(!active)return;setLoading(false);if(statement.error||ledger.error){setError("Statement matching could not be loaded. Refresh reports and try again.");return;}setLines((statement.data??[])as StatementLine[]);setCandidates((ledger.data??[])as LedgerCandidate[]);},()=>{if(active){setLoading(false);setError("Statement matching is temporarily unavailable.");}});
    return()=>{active=false;};
  },[reconciliationId,revision]);
  const unmatchedLines=lines.filter(line=>line.status!=="matched").length;
  const unmatchedLedger=candidates.filter(candidate=>candidate.status!=="matched").length;
  return <div className="statement-workspace">
    <div className="panel-heading"><div><strong>Statement transaction matching</strong><small>Positive amounts are money received; negative amounts are money paid. Completion requires every imported line and ledger movement to be matched.</small></div>{loading&&<span className="report-loading"><LoaderCircle size={14} className="spin"/>Loading</span>}</div>
    {error&&<p className="form-error report-error" role="alert">{error}</p>}
    {!error&&<>
      <div className="statement-summary"><span><b>{lines.length}</b> statement lines</span><span><b>{unmatchedLines}</b> unmatched lines</span><span><b>{unmatchedLedger}</b> unmatched ledger movements</span></div>
      {canEdit&&<div className="statement-tools"><ImportStatement reconciliationId={reconciliationId} saved={refresh}/><AutoMatch reconciliationId={reconciliationId} saved={refresh}/></div>}
      <div className="table-wrap"><table><thead><tr><th>Date</th><th>Statement transaction</th><th>Amount</th><th>Status</th><th>Match / review</th></tr></thead><tbody>{lines.map(line=><tr key={line.line_id}><td>{line.transaction_date}</td><td><strong>{line.description}</strong><small className="statement-reference">{line.reference||"No reference"}</small></td><td className="tabular">{money(Number(line.amount_kobo))}</td><td><span className={`status-pill ${line.status==="matched"?"green-pill":line.status==="exception"?"red-pill":"amber-pill"}`}>{line.status}</span>{line.exception_reason&&<small className="statement-reference">{line.exception_reason}</small>}</td><td>{line.status==="matched"&&line.match_id&&canEdit?<VoidMatch matchId={line.match_id} saved={refresh}/>:canEdit?<LineReview line={line} candidates={candidates.filter(candidate=>candidate.status==="unmatched"&&Number(candidate.amount_kobo)===Number(line.amount_kobo))} saved={refresh}/>:"—"}</td></tr>)}</tbody></table>{!loading&&!lines.length&&<div className="empty-state">Import a CSV statement to begin transaction matching.</div>}</div>
      <details className="ledger-candidates"><summary>Ledger movements · {unmatchedLedger} unmatched</summary><div className="table-wrap"><table><thead><tr><th>Date</th><th>Ledger entry</th><th>Source</th><th>Amount</th><th>Status</th></tr></thead><tbody>{candidates.map(candidate=><tr key={candidate.journal_id}><td>{candidate.journal_date}</td><td>{candidate.memo}</td><td>{candidate.source_type.replaceAll("_"," ")}</td><td>{money(Number(candidate.amount_kobo))}</td><td>{candidate.status}</td></tr>)}</tbody></table>{!candidates.length&&<div className="empty-state">No posted movements for this payment account and period.</div>}</div></details>
    </>}
  </div>;
}

function useIdempotencyKey() {const[key,setKey]=useState("");const renew=useCallback(()=>setKey(crypto.randomUUID()),[]);useEffect(()=>renew(),[renew]);return {key,renew};}

function ImportStatement({reconciliationId,saved}:{reconciliationId:string;saved:()=>void}) {
  const[state,action,pending]=useActionState(importBankStatementAction,{} as ActionState);const{key,renew}=useIdempotencyKey();
  useEffect(()=>{if(state.success){renew();saved();}},[state.success,saved,renew]);
  return <form action={action} className="statement-import-form"><input type="hidden" name="reconciliation_id" value={reconciliationId}/><input type="hidden" name="idempotency_key" value={key}/><label>Import CSV<input type="file" name="statement_file" accept=".csv,text/csv" required/></label><button className="button button-primary" disabled={pending||!key}>{pending?"Importing…":"Import statement"}</button>{state.error&&<span className="form-error">{state.error}</span>}{state.success&&<span className="admin-success">Statement imported.</span>}<small>Headers: date, description, reference, amount, balance. Or use debit and credit instead of signed amount. Dates may be YYYY-MM-DD or DD/MM/YYYY.</small></form>;
}

function AutoMatch({reconciliationId,saved}:{reconciliationId:string;saved:()=>void}) {
  const[state,action,pending]=useActionState(autoMatchBankStatementAction,{} as ActionState);
  useEffect(()=>{if(state.success)saved();},[state.success,saved]);
  return <form action={action} className="statement-auto-form"><input type="hidden" name="reconciliation_id" value={reconciliationId}/><button className="button" disabled={pending}>{pending?"Matching…":"Auto-match exact amounts"}</button>{state.success&&<small>{state.result} transaction{state.result==="1"?"":"s"} matched.</small>}{state.error&&<span className="form-error">{state.error}</span>}</form>;
}

function LineReview({line,candidates,saved}:{line:StatementLine;candidates:LedgerCandidate[];saved:()=>void}) {
  return <details className="statement-review"><summary>Resolve</summary>{candidates.length?<ManualMatch lineId={line.line_id} candidates={candidates} saved={saved}/>:<p className="optional">No unmatched ledger entry has this exact amount.</p>}<FlagException lineId={line.line_id} saved={saved}/></details>;
}

function ManualMatch({lineId,candidates,saved}:{lineId:string;candidates:LedgerCandidate[];saved:()=>void}) {
  const[state,action,pending]=useActionState(matchBankStatementLineAction,{} as ActionState);const{key,renew}=useIdempotencyKey();
  useEffect(()=>{if(state.success){renew();saved();}},[state.success,saved,renew]);
  return <form action={action} className="statement-inline-form"><input type="hidden" name="statement_line_id" value={lineId}/><input type="hidden" name="idempotency_key" value={key}/><select name="journal_id" required defaultValue=""><option value="" disabled>Choose ledger entry</option>{candidates.map(candidate=><option key={candidate.journal_id} value={candidate.journal_id}>{candidate.journal_date} · {candidate.memo}</option>)}</select><input name="reason" maxLength={500} placeholder="Match note (optional)"/><button className="button" disabled={pending||!key}>{pending?"Saving…":"Match"}</button>{state.error&&<span className="form-error">{state.error}</span>}</form>;
}

function FlagException({lineId,saved}:{lineId:string;saved:()=>void}) {
  const[state,action,pending]=useActionState(flagBankStatementExceptionAction,{} as ActionState);const{key,renew}=useIdempotencyKey();
  useEffect(()=>{if(state.success){renew();saved();}},[state.success,saved,renew]);
  return <form action={action} className="statement-inline-form"><input type="hidden" name="statement_line_id" value={lineId}/><input type="hidden" name="idempotency_key" value={key}/><input name="reason" required minLength={5} maxLength={500} placeholder="Why is this unmatched?"/><button className="text-button" disabled={pending||!key}>{pending?"Saving…":"Flag exception"}</button>{state.error&&<span className="form-error">{state.error}</span>}</form>;
}

function VoidMatch({matchId,saved}:{matchId:string;saved:()=>void}) {
  const[state,action,pending]=useActionState(voidBankStatementMatchAction,{} as ActionState);
  useEffect(()=>{if(state.success)saved();},[state.success,saved]);
  return <details className="statement-review"><summary>Correct match</summary><form action={action} className="statement-inline-form"><input type="hidden" name="match_id" value={matchId}/><input name="reason" required minLength={5} maxLength={500} placeholder="Correction reason"/><button className="text-button" disabled={pending}>{pending?"Saving…":"Remove match"}</button>{state.error&&<span className="form-error">{state.error}</span>}</form></details>;
}
