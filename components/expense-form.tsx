"use client";

import { useActionState, useEffect, useState } from "react";
import { LoaderCircle } from "lucide-react";
import { postExpenseAction, type ActionState } from "@/app/actions";
import type { PaymentMethodOption, DepartmentOption } from "@/components/hotel-dashboard";

export function ExpenseForm({ propertyId, methods, departments }: { propertyId: string; methods: PaymentMethodOption[]; departments: DepartmentOption[] }) {
  const [state, action, pending] = useActionState(postExpenseAction, {} as ActionState);
  const [key, setKey] = useState("");
  useEffect(() => { setKey(crypto.randomUUID()); }, []);
  if (state.success) return <div className="folio-success">Expense posted to the ledger.{state.notice && <p className="form-error">{state.notice}</p>}<button className="button" type="button" onClick={() => window.location.reload()}>Enter another expense</button></div>;
  return <form action={action} className="reservation-form expense-form">
    <input type="hidden" name="property_id" value={propertyId}/><input type="hidden" name="idempotency_key" value={key}/>
    <div className="reservation-form-row"><label>Description<input name="description" minLength={2} required placeholder="Generator fuel, supplies…"/></label><label>Vendor<input name="vendor" placeholder="Supplier name"/></label></div>
    <div className="reservation-form-row"><label>Category<select name="expense_account_code" defaultValue="5000"><option value="5000">Operating expenses</option><option value="5010">Utilities</option><option value="5020">Repairs and maintenance</option><option value="5030">Staff costs</option><option value="5040">Guest and housekeeping supplies</option><option value="5050">Food and beverage</option><option value="5060">Transport and logistics</option><option value="5070">Sales and marketing</option><option value="5090">Other operating expenses</option></select></label><label>Amount (₦)<input name="amount" type="number" min="0.01" step="0.01" required/></label><label>Paid with<select name="payment_method_id" required>{methods.map(method => <option key={method.id} value={method.id}>{method.name}</option>)}</select></label></div>
    <label>Department<select name="department_id" required defaultValue={departments.find(department => department.code === "administration")?.id}>{departments.map(department => <option key={department.id} value={department.id}>{department.name}</option>)}</select></label>
    <label>Receipt <span className="optional">Optional · JPG, PNG, PDF · up to 10 MB</span><input name="receipt_file" type="file" accept="image/jpeg,image/png,application/pdf"/></label>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}
    <button className="button button-primary" disabled={pending || !key || !methods.length}>{pending && <LoaderCircle size={14} className="spin"/>}Post paid expense</button>
  </form>;
}
