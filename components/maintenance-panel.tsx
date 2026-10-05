"use client";

import { useActionState, useCallback, useEffect, useState } from "react";
import { reportMaintenanceAction, transitionMaintenanceAction, type ActionState } from "@/app/actions";
import { createClient } from "@/lib/supabase/client";
import type { LiveRoom } from "@/components/hotel-dashboard";

type WorkOrder = { id: string; room_id: string; title: string; description: string | null; priority: string;
  status: string; blocks_inventory: boolean; resolution_notes: string | null; created_at: string };

function ReportIssue({ rooms, canBlock, onSaved }: { rooms: LiveRoom[]; canBlock: boolean; onSaved: () => void }) {
  const [state, action, pending] = useActionState(reportMaintenanceAction, {} as ActionState);
  const [key, setKey] = useState("");
  useEffect(() => { setKey(crypto.randomUUID()); }, []);
  useEffect(() => { if (state.success) onSaved(); }, [state.success, onSaved]);
  return <form action={action} className="reservation-form">
    <input type="hidden" name="idempotency_key" value={key}/>
    <div className="reservation-form-row"><label>Room<select name="room_id" required>{rooms.map(room => <option key={room.id} value={room.id}>{room.number} · {room.type}</option>)}</select></label><label>Priority<select name="priority" defaultValue="normal"><option value="low">Low</option><option value="normal">Normal</option><option value="urgent">Urgent</option></select></label></div>
    <label>Issue title<input name="title" required minLength={3} maxLength={120} placeholder="e.g. Air conditioner leaking"/></label>
    <label>Details<textarea name="description" maxLength={2000} rows={2}/></label>
    {canBlock && <label><span><input type="checkbox" name="blocks_inventory"/> Block room from sale until this task is closed</span><span className="optional">Move any in-house guest first. Existing future reservations need review.</span></label>}
    {state.error && <p role="alert" className="form-error">{state.error}</p>}
    <button className="button button-primary" disabled={pending || !key || !rooms.length}>{pending ? "Saving…" : "Report issue"}</button>
  </form>;
}

function UpdateIssue({ order, onSaved }: { order: WorkOrder; onSaved: () => void }) {
  const [state, action, pending] = useActionState(transitionMaintenanceAction, {} as ActionState);
  const [status, setStatus] = useState(order.status === "open" ? "in_progress" : "resolved");
  useEffect(() => { if (state.success) onSaved(); }, [state.success, onSaved]);
  return <form action={action} className="reservation-form">
    <input type="hidden" name="work_order_id" value={order.id}/>
    <label>Status<select name="status" value={status} onChange={event => setStatus(event.target.value)}>{order.status === "open" && <option value="in_progress">In progress</option>}<option value="resolved">Resolved</option><option value="cancelled">Cancelled</option></select></label>
    <label>Work / closing notes<textarea name="notes" rows={2} maxLength={2000} minLength={5} required={status !== "in_progress"} placeholder="Work performed or reason for cancellation"/></label>
    {state.error && <p role="alert" className="form-error">{state.error}</p>}
    <button className="button" disabled={pending}>{pending ? "Saving…" : "Update task"}</button>
  </form>;
}

export function MaintenancePanel({ organizationId, propertyId, rooms, role }: { organizationId: string; propertyId: string; rooms: LiveRoom[]; role: string }) {
  const [orders, setOrders] = useState<WorkOrder[]>([]);
  const [revision, setRevision] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const canManage = ["owner", "manager"].includes(role);
  const canReport = ["owner", "manager", "front_desk", "housekeeping"].includes(role);
  const saved = useCallback(() => { setRevision(value => value + 1); setNotice("Maintenance task saved."); }, []);
  useEffect(() => {
    let active = true;
    setLoading(true); setError("");
    createClient().from("maintenance_work_orders").select("id,room_id,title,description,priority,status,blocks_inventory,resolution_notes,created_at")
      .eq("organization_id", organizationId).eq("property_id", propertyId).order("created_at", { ascending: false }).limit(100)
      .then(({ data, error: requestError }) => {
        if (!active) return;
        setLoading(false);
        if (requestError) { setError("Maintenance tasks could not be loaded. Contact the hotel administrator."); setOrders([]); }
        else setOrders((data ?? []) as WorkOrder[]);
      }, () => { if (active) { setLoading(false); setError("Maintenance tasks could not be loaded. Try refreshing."); } });
    return () => { active = false; };
  }, [organizationId, propertyId, revision]);
  return <section className="panel maintenance-panel">
    <div className="panel-heading"><div><h2>Maintenance work orders</h2><p>Track repairs and manager-approved room blocks separately from housekeeping.</p></div><button className="button" onClick={() => setRevision(value => value + 1)}>Refresh</button></div>
    {notice && <p className="folio-success" role="status">{notice}</p>}
    {error && <p className="form-error" role="alert">{error}</p>}
    <div className="maintenance-layout">
      {canReport && <div><h3>Report an issue</h3><ReportIssue key={`${propertyId}:${revision}`} rooms={rooms} canBlock={canManage} onSaved={saved}/></div>}
      <div><h3>Recent tasks</h3>{loading ? <p role="status">Loading tasks…</p> : !orders.length ? <p>No maintenance tasks recorded.</p> : orders.map(order => <article className="maintenance-order" key={`${order.id}:${order.status}`}>
        <strong>Room {rooms.find(room => room.id === order.room_id)?.number ?? "—"} · {order.title}</strong>
        <p>{order.priority} priority · {order.status.replaceAll("_", " ")} · {new Date(order.created_at).toLocaleDateString("en-NG")}</p>
        {order.description && <p>{order.description}</p>}
        {order.blocks_inventory && ["open", "in_progress"].includes(order.status) && <p className="form-error">Room blocked from sale — review any existing reservations.</p>}
        {order.resolution_notes && <p>Work notes: {order.resolution_notes}</p>}
        {canManage && ["open", "in_progress"].includes(order.status) && <UpdateIssue order={order} onSaved={saved}/>}
      </article>)}</div>
    </div>
  </section>;
}
