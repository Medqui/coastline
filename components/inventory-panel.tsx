"use client";
import { useActionState, useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { saveStockItemAction, recordStockMovementAction, type ActionState } from "@/app/actions";
import type { HotelContext } from "@/components/hotel-dashboard";

type Item = { id: string; name: string; unit: string; par_level: number; on_hand: number };
type Movement = { id: string; item_id: string; quantity: number; reason: string; created_at: string };
export function InventoryPanel({ context }: { context?: HotelContext }) {
  const [items, setItems] = useState<Item[]>([]); const [movements, setMovements] = useState<Movement[]>([]);
  const [revision, setRevision] = useState(0); const [loading, setLoading] = useState(Boolean(context)); const [error, setError] = useState("");
  const [notice, setNotice] = useState(""); const [query, setQuery] = useState("");
  const saved = useCallback(() => { setRevision(value => value + 1); setNotice("Inventory saved."); }, []);
  const propertyId = context?.propertyId;
  useEffect(() => {
    if (!propertyId) return; let active = true; setLoading(true); setError("");
    const client = createClient();
    Promise.all([client.from("stock_balances").select("id,name,unit,par_level,on_hand").eq("property_id", propertyId).order("name"), client.from("stock_movements").select("id,item_id,quantity,reason,created_at").eq("property_id", propertyId).order("created_at", { ascending: false }).limit(100)]).then(([stock, history]) => {
      if (!active) return; setLoading(false);
      if (stock.error || history.error) { setItems([]); setMovements([]); setError("Inventory could not be loaded. Ask the administrator to check the latest hotel update."); return; }
      setItems((stock.data ?? []).map(item => ({ ...item, par_level: Number(item.par_level), on_hand: Number(item.on_hand) })));
      setMovements((history.data ?? []).map(row => ({ ...row, quantity: Number(row.quantity) })));
    }, () => { if (active) { setLoading(false); setError("Inventory could not be loaded. Refresh to try again."); setItems([]); setMovements([]); } });
    return () => { active = false; };
  }, [propertyId, revision]);
  return <><div className="page-heading"><div><div className="eyebrow">STOCK & SUPPLIES</div><h1>Inventory</h1><p>Track food, drinks, toiletries and supplies. Record receipts and issues with an audit reason.</p></div><button className="button" onClick={() => setRevision(value => value+1)}>Refresh</button></div>
    <p className="demo-notice">This increment tracks quantities and low stock. Purchase orders, storage locations, valuation and automatic cost-of-sales postings are planned. Supplier invoices remain in Accounting.</p>
    {!context ? <section className="panel empty-state">Connect your hotel to track stock.</section> : loading ? <p role="status">Loading inventory…</p> : error ? <p className="form-error" role="alert">{error}</p> : <>
      {notice && <p className="folio-success" role="status">{notice}</p>}
      <section className="panel"><div className="panel-heading"><strong>On-hand stock</strong><input className="select-control" aria-label="Search stock" placeholder="Search stock" value={query} onChange={event => setQuery(event.target.value)}/></div><div className="table-wrap"><table><thead><tr><th>Item</th><th>Unit</th><th>On hand</th><th>Par level</th><th>Status</th></tr></thead><tbody>{items.filter(item => item.name.toLowerCase().includes(query.toLowerCase())).map(item => <tr key={item.id}><td>{item.name}</td><td>{item.unit}</td><td>{item.on_hand}</td><td>{item.par_level}</td><td><span className={`status-pill ${item.on_hand < item.par_level ? "amber-pill" : "green-pill"}`}>{item.on_hand < item.par_level ? "Low stock" : "In stock"}</span></td></tr>)}</tbody></table>{!items.length && <p className="empty-state">Create an item, then record its opening stock.</p>}</div></section>
      <div className="content-grid two-col settings-content"><section className="panel"><div className="panel-heading"><strong>Add stock item</strong></div><ItemForm key={`item:${revision}`} propertyId={context.propertyId} saved={saved}/></section><section className="panel"><div className="panel-heading"><strong>Receive / issue stock</strong></div><MovementForm key={`movement:${revision}`} items={items} saved={saved}/></section></div>
      <section className="panel"><div className="panel-heading"><strong>Latest 100 stock movements</strong><small>Corrections use a new movement; original records are retained.</small></div><div className="table-wrap"><table><thead><tr><th>Date</th><th>Item</th><th>Quantity</th><th>Reason</th></tr></thead><tbody>{movements.map(row => <tr key={row.id}><td>{new Date(row.created_at).toLocaleString("en-NG", { timeZone: "Africa/Lagos" })}</td><td>{items.find(item => item.id === row.item_id)?.name ?? "Stock item"}</td><td>{row.quantity > 0 ? "+" : ""}{row.quantity}</td><td>{row.reason}</td></tr>)}</tbody></table>{!movements.length && <p className="empty-state">No movements yet.</p>}</div></section>
    </>}
  </>;
}
function ItemForm({ propertyId, saved }: { propertyId: string; saved: () => void }) {
  const [state, action, pending] = useActionState(saveStockItemAction, {} as ActionState);
  useEffect(() => { if (state.success) saved(); }, [state.success, saved]);
  return <form action={action} className="reservation-form"><input name="property_id" type="hidden" value={propertyId}/><label>Item name<input name="name" required maxLength={120}/></label><label>Unit<input name="unit" required maxLength={40} placeholder="bottle, kg, pack…"/></label><label>Low-stock par level<input name="par_level" type="number" min={0} step="0.001" defaultValue={0} required/></label>{state.error && <p className="form-error" role="alert">{state.error}</p>}<button className="button button-primary" disabled={pending}>{pending ? "Saving…" : "Create item"}</button></form>;
}
function MovementForm({ items, saved }: { items: Item[]; saved: () => void }) {
  const [state, action, pending] = useActionState(recordStockMovementAction, {} as ActionState);
  const [key, setKey] = useState(""); useEffect(() => { setKey(crypto.randomUUID()); }, []);
  useEffect(() => { if (state.success) saved(); }, [state.success, saved]);
  return <form action={action} className="reservation-form"><input name="idempotency_key" type="hidden" value={key}/><label>Item<select name="item_id" required>{items.map(item => <option key={item.id} value={item.id}>{item.name} ({item.unit})</option>)}</select></label><label>Quantity change<input name="quantity" type="number" step="0.001" required placeholder="10 to receive, -2 to issue"/></label><label>Reason<input name="reason" required minLength={5} maxLength={500} placeholder="Delivery, opening count, consumption, correction…"/></label>{state.error && <p className="form-error" role="alert">{state.error}</p>}<button className="button button-primary" disabled={pending || !key || !items.length}>{pending ? "Saving…" : "Record movement"}</button></form>;
}
