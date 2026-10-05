"use client";
import { useEffect, useState } from "react";
import { ExternalLink } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

type Expense = { id: string; date: string; vendor: string; description: string; amountKobo: number; receiptPath: string };
export function ExpenseList({ expenses }: { expenses: Expense[] }) {
  return <section className="panel expense-history"><div className="panel-heading"><div><strong>Recent expenses</strong><small>Paid expenses with receipt links when a file was attached.</small></div></div><div className="table-wrap"><table><thead><tr><th>Date</th><th>Description</th><th>Vendor</th><th>Amount</th><th>Receipt</th></tr></thead><tbody>{expenses.map(expense=><tr key={expense.id}><td>{expense.date}</td><td>{expense.description}</td><td>{expense.vendor||"—"}</td><td className="tabular">₦{new Intl.NumberFormat("en-NG",{minimumFractionDigits:2,maximumFractionDigits:2}).format(expense.amountKobo/100)}</td><td>{expense.receiptPath?<ReceiptLink path={expense.receiptPath}/>:"—"}</td></tr>)}</tbody></table>{!expenses.length&&<div className="empty-state">No expenses have been posted for this property yet.</div>}</div></section>;
}
function ReceiptLink({path}:{path:string}) {
  const [url,setUrl]=useState("");
  useEffect(()=>{let active=true;const client=createClient();client.storage.from("expense-receipts").createSignedUrl(path,60).then(({data})=>{if(active&&data?.signedUrl)setUrl(data.signedUrl);});return()=>{active=false;};},[path]);
  return url?<a className="receipt-link" href={url} target="_blank" rel="noreferrer"><ExternalLink size={13}/>View receipt</a>:<span className="receipt-pending">{path?"Loading…":"—"}</span>;
}
