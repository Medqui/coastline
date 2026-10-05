"use client";

import { useActionState, useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { savePropertyConfigurationAction, type ActionState } from "@/app/actions";
import type { HotelContext } from "@/components/hotel-dashboard";
import { RoomRatesPanel } from "@/components/room-rates-panel";
import { PropertyForm } from "@/components/admin-panel";

type RecordRow = { id: string; name?: string; room_number?: string; floor_label?: string; room_type_id?: string; active?: boolean; max_occupancy?: number; base_rate_kobo?: number; clearing_account_code?: string; rate_basis_points?: number; address?: string; city?: string; check_in_time?: string; check_out_time?: string };
type Configuration = { property: RecordRow[]; room_type: RecordRow[]; room: RecordRow[]; floor: RecordRow[]; payment_method: RecordRow[]; tax: RecordRow[] };
type Kind = keyof Configuration;
const tabs = ["Hotel information", "Room Types", "Rooms", "Floors", "Rates", "Taxes & Charges", "Payment Methods", "Roles & Permissions", "Properties"] as const;
type Tab = typeof tabs[number];
const kinds: Partial<Record<Tab, Kind>> = { "Hotel information": "property", "Room Types": "room_type", Rooms: "room", Floors: "floor", "Taxes & Charges": "tax", "Payment Methods": "payment_method" };
const empty: Configuration = { property: [], room_type: [], room: [], floor: [], payment_method: [], tax: [] };

export function PropertySettings({ context }: { context?: HotelContext }) {
  const [tab, setTab] = useState<Tab>("Hotel information");
  const [config, setConfig] = useState<Configuration>(empty);
  const [revision, setRevision] = useState(0);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(Boolean(context));
  const [selectedId, setSelectedId] = useState("");
  const [notice, setNotice] = useState("");
  const saved = useCallback(() => { setRevision(value => value + 1); setSelectedId(""); setNotice("Configuration saved. Room changes also appear in live Rooms."); }, []);
  const propertyId = context?.propertyId;
  useEffect(() => {
    if (!propertyId) return;
    let active = true; setLoading(true); setError("");
    const client = createClient();
    Promise.all([
      client.from("properties").select("id,name,address,city,check_in_time,check_out_time").eq("id", propertyId),
      client.from("room_types").select("id,name,base_rate_kobo,max_occupancy,active").eq("property_id", propertyId).order("name"),
      client.from("rooms").select("id,room_number,room_type_id,floor_label,active").eq("property_id", propertyId).order("room_number"),
      client.from("property_floors").select("id,name").eq("property_id", propertyId).order("name"),
      client.from("payment_methods").select("id,name,clearing_account_code,active").eq("property_id", propertyId).order("name"),
      client.from("property_tax_rules").select("id,name,rate_basis_points,active").eq("property_id", propertyId).order("name"),
    ]).then(results => {
      if (!active) return; setLoading(false);
      if (results.some(result => result.error)) { setConfig(empty); setError("Settings could not be loaded. Ask the administrator to install the latest hotel update, then refresh."); return; }
      const [property, room_type, room, floor, payment_method, tax] = results.map(result => result.data ?? []);
      setConfig({ property, room_type, room, floor, payment_method, tax } as Configuration);
    }, () => { if (active) { setLoading(false); setConfig(empty); setError("Settings could not be loaded. Try again."); } });
    return () => { active = false; };
  }, [propertyId, revision]);
  const kind = kinds[tab];
  const rows = kind ? config[kind] : [];
  const record = kind === "property" ? rows[0] : rows.find(row => row.id === selectedId);
  return <><div className="page-heading"><div><div className="eyebrow">HOTEL CONFIGURATION</div><h1>Settings</h1><p>Administrators define rooms here. Daily occupancy and room readiness are managed in Rooms and Housekeeping.</p></div></div>
    <div className="module-tabs" role="tablist" aria-label="Settings sections">{tabs.map(item => <button className={`button ${tab === item ? "button-primary" : ""}`} role="tab" aria-selected={tab === item} key={item} onClick={() => { setTab(item); setSelectedId(""); setNotice(""); }}>{item}</button>)}</div>
    {!context ? <section className="panel empty-state">Connect your hotel to configure room types, physical rooms, floors and rates.</section> : <div className="settings-content" role="tabpanel">
      {notice && <p className="folio-success" role="status">{notice}</p>}
      {tab === "Rates" ? <RoomRatesPanel propertyId={context.propertyId} role={context.role}/> : tab === "Properties" ? <section className="panel"><div className="panel-heading"><strong>Add a property</strong></div><PropertyForm organizationId={context.organizationId}/></section> : tab === "Roles & Permissions" ? <section className="panel"><div className="panel-heading"><strong>Supported roles</strong></div><div className="table-wrap"><table><thead><tr><th>Role</th><th>Responsibility</th></tr></thead><tbody>{[["Owner","All modules, staff invitations and role changes"],["Manager","Property configuration, daily operations and financial oversight"],["Front desk","Reservations, check-in/out, room views, guest charges and payments"],["Housekeeping","Room readiness and cleaning status"],["Accountant","Accounting, inventory records and reports"]].map(([role, scope]) => <tr key={role}><td>{role}</td><td>{scope}</td></tr>)}</tbody></table></div><p className="empty-state">Assign these roles in Staff. Permissions are enforced by the database. Custom roles are not yet supported.</p></section> : <>
        {loading ? <p role="status">Loading hotel settings…</p> : error ? <section className="panel empty-state"><p className="form-error" role="alert">{error}</p><button className="button" onClick={() => setRevision(value => value+1)}>Refresh settings</button></section> : kind && <>
          {kind === "tax" && <p className="demo-notice">These rules save your tax setup for the next billing increment. They are not automatically added to guest charges yet.</p>}
          {kind !== "property" && <section className="panel"><div className="panel-heading"><strong>{tab}</strong><button className="button" onClick={() => setSelectedId("")}>Add {kind.replaceAll("_", " ")}</button></div><div className="table-wrap"><table><thead><tr><th>Name / number</th><th>Details</th><th>Configuration</th><th>Action</th></tr></thead><tbody>{rows.map(row => <tr key={row.id}><td>{row.name ?? row.room_number}</td><td>{kind === "room" ? `${config.room_type.find(type => type.id === row.room_type_id)?.name ?? "Room type"} · ${row.floor_label ?? "No floor"}` : kind === "room_type" ? `Capacity ${row.max_occupancy} · ₦${Number(row.base_rate_kobo)/100}/night` : kind === "tax" ? `${Number(row.rate_basis_points)/100}%` : row.clearing_account_code ?? "Floor"}</td><td>{row.active === false ? "Inactive" : "Active"}</td><td><button className="text-button" onClick={() => setSelectedId(row.id)}>Edit</button></td></tr>)}</tbody></table>{!rows.length && <p className="empty-state">No records yet. Add the first one below.</p>}</div></section>}
          <section className="panel"><div className="panel-heading"><strong>{record ? "Edit" : "Add"} {kind.replaceAll("_", " ")}</strong></div><ConfigurationForm key={`${kind}:${record?.id ?? "new"}:${revision}`} propertyId={context.propertyId} kind={kind} record={record} config={config} saved={saved}/></section>
        </>}
      </>}
    </div>}
  </>;
}
function ConfigurationForm({ propertyId, kind, record, config, saved }: { propertyId: string; kind: Kind; record?: RecordRow; config: Configuration; saved: () => void }) {
  const [state, action, pending] = useActionState(savePropertyConfigurationAction, {} as ActionState);
  useEffect(() => { if (state.success) saved(); }, [state.success, saved]);
  const isRoom = kind === "room";
  return <form action={action} className="reservation-form"><input type="hidden" name="property_id" value={propertyId}/><input type="hidden" name="kind" value={kind}/><input type="hidden" name="id" value={record?.id ?? ""}/>
    <label>{isRoom ? "Room number" : "Name"}<input name={isRoom ? "room_number" : "name"} defaultValue={record?.room_number ?? record?.name ?? ""} required maxLength={120}/></label>
    {kind === "property" && <><label>Address<input name="address" defaultValue={record?.address ?? ""}/></label><label>City<input name="city" required defaultValue={record?.city ?? "Calabar"}/></label><div className="reservation-form-row"><label>Check-in time<input name="check_in_time" type="time" required defaultValue={record?.check_in_time?.slice(0,5) ?? "14:00"}/></label><label>Check-out time<input name="check_out_time" type="time" required defaultValue={record?.check_out_time?.slice(0,5) ?? "12:00"}/></label></div></>}
    {kind === "room_type" && <><label>Capacity<input name="max_occupancy" type="number" min={1} max={20} required defaultValue={record?.max_occupancy ?? 2}/></label>{!record && <label>Base nightly rate (₦)<input name="rate" type="number" min={0} step="0.01" required/></label>}<p>Change existing base and seasonal rates in the Rates tab. Agreed booking prices are preserved.</p></>}
    {isRoom && <><label>Room type<select name="room_type_id" required defaultValue={record?.room_type_id ?? ""}><option value="" disabled>Select a room type</option>{config.room_type.filter(type => type.active || type.id === record?.room_type_id).map(type => <option value={type.id} key={type.id}>{type.name}</option>)}</select></label><label>Floor<select name="floor_label" defaultValue={record?.floor_label ?? ""}><option value="">No floor assigned</option>{config.floor.map(floor => <option key={floor.id} value={floor.name}>{floor.name}</option>)}</select></label><p>New rooms start dirty and must be cleaned before check-in. Add one physical room at a time in this increment.</p></>}
    {kind === "payment_method" && <label>Payment account<select name="clearing_account_code" defaultValue={record?.clearing_account_code ?? "1000"}><option value="1000">Cash</option><option value="1010">Bank transfer</option><option value="1020">Card / POS clearing</option></select></label>}
    {kind === "tax" && <label>Percentage<input name="percent" type="number" min={0} max={100} step="0.01" required defaultValue={Number(record?.rate_basis_points ?? 0)/100}/></label>}
    {!["property","floor"].includes(kind) && <label><span><input name="active" type="checkbox" defaultChecked={record?.active ?? true}/> Active</span></label>}
    {state.error && <p className="form-error" role="alert">{state.error}</p>}<button className="button button-primary" disabled={pending || (isRoom && !config.room_type.length)}>{pending ? "Saving…" : record ? "Save changes" : "Create"}</button>
  </form>;
}
