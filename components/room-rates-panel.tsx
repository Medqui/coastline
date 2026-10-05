"use client";

import { useActionState, useCallback, useEffect, useState } from "react";
import { setRoomBaseRateAction, scheduleRoomRateAction, retireRoomRateAction, type ActionState } from "@/app/actions";
import { createClient } from "@/lib/supabase/client";

type RoomType = { id: string; name: string; base_rate_kobo: number };
type RatePeriod = { id: string; room_type_id: string; name: string; starts_on: string; ends_before: string; nightly_rate_kobo: number; active: boolean };
const money = (kobo: number) => new Intl.NumberFormat("en-NG", { style: "currency", currency: "NGN" }).format(kobo / 100);
function lastNight(endsBefore: string) {
  const date = new Date(`${endsBefore}T00:00:00Z`); date.setUTCDate(date.getUTCDate() - 1); return date.toISOString().slice(0,10);
}
function BaseRateForm({ types, saved }: { types: RoomType[]; saved: () => void }) {
  const [state, action, pending] = useActionState(setRoomBaseRateAction, {} as ActionState);
  const [typeId, setTypeId] = useState(types[0]?.id ?? "");
  const [rate, setRate] = useState(((types[0]?.base_rate_kobo ?? 0)/100).toFixed(2));
  useEffect(() => { if (state.success) saved(); }, [state.success,saved]);
  return <form className="reservation-form" action={action}>
    <label>Room type<select name="room_type_id" value={typeId} onChange={event => { setTypeId(event.target.value); setRate(((types.find(type => type.id===event.target.value)?.base_rate_kobo ?? 0)/100).toFixed(2)); }}>{types.map(type => <option key={type.id} value={type.id}>{type.name}</option>)}</select></label>
    <label>Base nightly rate (₦)<input name="rate" type="number" min={0} step="0.01" required value={rate} onChange={event => setRate(event.target.value)}/></label>
    <label>Reason<input name="reason" minLength={5} maxLength={500} required/></label>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}
    <button className="button button-primary" disabled={pending}>{pending ? "Saving…" : "Update base rate"}</button>
  </form>;
}
function ScheduledRateForm({ types, saved }: { types: RoomType[]; saved: () => void }) {
  const [state, action, pending] = useActionState(scheduleRoomRateAction, {} as ActionState);
  useEffect(() => { if (state.success) saved(); }, [state.success,saved]);
  return <form className="reservation-form" action={action}>
    <label>Room type<select name="room_type_id">{types.map(type => <option key={type.id} value={type.id}>{type.name}</option>)}</select></label>
    <label>Rate name<input name="name" minLength={2} maxLength={120} required placeholder="e.g. Christmas season"/></label>
    <div className="reservation-form-row"><label>First night<input name="first_night" type="date" required/></label><label>Last night<input name="last_night" type="date" required/></label></div>
    <label>Nightly rate (₦)<input name="rate" type="number" min={0} step="0.01" required/></label>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}
    <button className="button button-primary" disabled={pending}>{pending ? "Saving…" : "Schedule rate"}</button>
  </form>;
}
function RetireRateForm({ id, saved }: { id: string; saved: () => void }) {
  const [state, action, pending] = useActionState(retireRoomRateAction, {} as ActionState);
  useEffect(() => { if (state.success) saved(); }, [state.success,saved]);
  return <form className="reservation-form" action={action}><input name="period_id" type="hidden" value={id}/><label>Reason to stop using this rate<input name="reason" required minLength={5} maxLength={500}/></label>{state.error && <p className="form-error" role="alert">{state.error}</p>}<button className="button" disabled={pending}>Stop using rate</button></form>;
}
export function RoomRatesPanel({ propertyId, role }: { propertyId: string; role: string }) {
  const [types, setTypes] = useState<RoomType[]>([]);
  const [periods, setPeriods] = useState<RatePeriod[]>([]);
  const [revision, setRevision] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const canManage = ["owner","manager"].includes(role);
  const saved = useCallback(() => { setRevision(value => value+1); setNotice("Room rates saved. Existing bookings keep their agreed prices."); }, []);
  useEffect(() => {
    let active = true; setLoading(true); setError("");
    const supabase = createClient();
    Promise.all([
      supabase.from("room_types").select("id,name,base_rate_kobo").eq("property_id",propertyId).eq("active",true).order("name"),
      supabase.from("room_rate_periods").select("id,room_type_id,name,starts_on,ends_before,nightly_rate_kobo,active").eq("property_id",propertyId).order("starts_on",{ascending:false}).limit(100),
    ]).then(([typeResult,periodResult]) => {
      if (!active) return; setLoading(false);
      if (typeResult.error || periodResult.error) { setTypes([]); setPeriods([]); setError("Room rates could not be loaded. Contact the hotel administrator."); return; }
      setTypes((typeResult.data ?? []).map(type => ({ ...type, base_rate_kobo: Number(type.base_rate_kobo) })));
      setPeriods((periodResult.data ?? []).map(period => ({ ...period, nightly_rate_kobo: Number(period.nightly_rate_kobo) })));
    }, () => { if (active) { setLoading(false); setError("Room rates could not be loaded. Try refreshing."); } });
    return () => { active = false; };
  },[propertyId,revision]);
  return <section className="panel maintenance-panel"><div className="panel-heading"><div><h2>Room rates</h2><p>Use the base rate outside scheduled dates. Saved bookings keep each agreed nightly price.</p></div><button className="button" onClick={() => setRevision(value => value+1)}>Refresh</button></div>
    {notice && <p className="folio-success" role="status">{notice}</p>}{error && <p className="form-error" role="alert">{error}</p>}
    {loading ? <p role="status">Loading room rates…</p> : <>
      <div className="rate-base-summary">{types.map(type => <p key={type.id}><strong>{type.name}</strong> · Base {money(type.base_rate_kobo)}/night</p>)}</div>
      {canManage && types.length>0 && <div className="maintenance-layout"><div><h3>Base rate</h3><BaseRateForm key={`base:${revision}:${propertyId}`} types={types} saved={saved}/></div><div><h3>Scheduled rate</h3><ScheduledRateForm key={`schedule:${revision}:${propertyId}`} types={types} saved={saved}/></div></div>}
      <div className="rate-period-list"><h3>Latest rate periods</h3>{periods.length ? periods.map(period => <article className="maintenance-order" key={`${period.id}:${period.active}`}><strong>{period.name} · {types.find(type => type.id===period.room_type_id)?.name ?? "Room type"}</strong><p>{period.starts_on}–{lastNight(period.ends_before)} · {money(period.nightly_rate_kobo)}/night · {period.active ? "In use" : "Retired"}</p>{canManage && period.active && <RetireRateForm id={period.id} saved={saved}/>}</article>) : <p>No rate periods scheduled. The base rate applies.</p>}</div>
    </>}
  </section>;
}
