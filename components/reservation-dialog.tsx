"use client";

import { useActionState, useEffect, useState } from "react";
import { CalendarDays, LoaderCircle, X } from "lucide-react";
import { createReservationAction, type ActionState } from "@/app/actions";
import { createClient } from "@/lib/supabase/client";

export type ReservationRoomOption = { id: string; number: string; type: string; rateKobo: number; status: string };

export function ReservationDialog({ organizationId, propertyId, role, initialArrival, initialRoomId, onClose }: {
  organizationId: string;
  propertyId: string;
  role: string;
  initialArrival?: string;
  initialRoomId?: string;
  onClose: () => void;
}) {
  const [state, action, pending] = useActionState(createReservationAction, {} as ActionState);
  const today = new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Lagos" });
  const tomorrow = new Date(Date.now() + 86400000).toLocaleDateString("en-CA", { timeZone: "Africa/Lagos" });
  const [arrival, setArrival] = useState(initialArrival ?? today);
  const initialDeparture = (() => {
    if (!initialArrival || !/^\d{4}-\d{2}-\d{2}$/.test(initialArrival)) return tomorrow;
    const date = new Date(`${initialArrival}T00:00:00Z`);
    if (Number.isNaN(date.getTime())) return tomorrow;
    date.setUTCDate(date.getUTCDate() + 1);
    return date.toISOString().slice(0, 10);
  })();
  const [departure, setDeparture] = useState(initialDeparture);
  const [availableRooms, setAvailableRooms] = useState<ReservationRoomOption[]>([]);
  const [roomId, setRoomId] = useState(initialRoomId ?? "");
  const [nightlyRate, setNightlyRate] = useState("");
  const [pricingMode, setPricingMode] = useState("standard");
  const [quote, setQuote] = useState<{ service_date: string; standard_rate_kobo: number; rate_name: string }[]>([]);
  const [quoteLoading, setQuoteLoading] = useState(true);
  const [quoteError, setQuoteError] = useState("");
  const [quoteRevision, setQuoteRevision] = useState(0);
  const [availabilityLoading, setAvailabilityLoading] = useState(true);
  const [availabilityError, setAvailabilityError] = useState("");
  const canApprovePricing = ["owner", "manager"].includes(role);
  const pricingOverride = pricingMode === "override" || quote.some(night => night.standard_rate_kobo === 0);
  const quotedTotal = pricingMode === "override" ? Number(nightlyRate) * 100 * quote.length : quote.reduce((sum, night) => sum + night.standard_rate_kobo, 0);
  const money = (kobo: number) => new Intl.NumberFormat("en-NG", { style: "currency", currency: "NGN" }).format(kobo / 100);
  useEffect(() => { setPricingMode("standard"); setNightlyRate(""); }, [roomId]);
  useEffect(() => { if (state.error?.includes("Room rates changed")) setQuoteRevision(value => value + 1); }, [state]);
  useEffect(() => {
    let active = true;
    setQuote([]); setQuoteError("");
    if (!roomId || !arrival || !departure || departure <= arrival) { setQuoteLoading(false); return; }
    if ((new Date(`${departure}T00:00:00Z`).getTime() - new Date(`${arrival}T00:00:00Z`).getTime()) / 86400000 > 366) {
      setQuoteLoading(false); setQuoteError("Choose a stay of at most 366 nights."); return;
    }
    setQuoteLoading(true);
    createClient().rpc("get_room_rate_quote", { p_room_id: roomId, p_arrival: arrival, p_departure: departure }).then(({ data, error }) => {
      if (!active) return;
      setQuoteLoading(false);
      if (error) { setQuoteError("The nightly quote could not be loaded. Try again or contact your manager."); return; }
      const nights = (data ?? []).map((night: { service_date: string; standard_rate_kobo: number; rate_name: string }) => ({ ...night, standard_rate_kobo: Number(night.standard_rate_kobo) }));
      setQuote(nights); setNightlyRate(value => value || ((nights[0]?.standard_rate_kobo ?? 0) / 100).toFixed(2));
    }, () => { if (active) { setQuoteLoading(false); setQuoteError("The nightly quote could not be loaded. Try again."); } });
    return () => { active = false; };
  }, [roomId, arrival, departure, quoteRevision]);
  useEffect(() => {
    let active = true;
    if (!arrival || !departure || departure <= arrival) { setAvailableRooms([]); setRoomId(""); setAvailabilityLoading(false); return; }
    setAvailabilityLoading(true); setAvailabilityError("");
    const supabase = createClient();
    supabase.rpc("get_available_rooms", { p_property_id: propertyId, p_arrival: arrival, p_departure: departure }).then(({ data, error }) => {
      if (!active) return;
      if (error) { setAvailabilityError(error.message); setAvailableRooms([]); setRoomId(""); }
      else {
        const rows: ReservationRoomOption[] = (data ?? []).map((row: { room_id: string; room_number: string; room_type: string; nightly_rate_kobo: number; housekeeping_status: string }) => ({ id: row.room_id, number: row.room_number, type: row.room_type, rateKobo: Number(row.nightly_rate_kobo), status: row.housekeeping_status }));
        setAvailableRooms(rows); setRoomId(rows.some(room => room.id === initialRoomId) ? initialRoomId! : rows[0]?.id ?? "");
      }
      setAvailabilityLoading(false);
    }, () => { if (active) { setAvailabilityError("Availability could not be loaded."); setAvailableRooms([]); setRoomId(""); setAvailabilityLoading(false); } });
    return () => { active = false; };
  }, [arrival, departure, propertyId, initialRoomId]);
  if (state.success) return <div className="modal-backdrop"><section className="reservation-modal"><button className="modal-close" onClick={onClose} aria-label="Close"><X size={18}/></button><div className="modal-success"><span><CalendarDays size={20}/></span><h2>Reservation created</h2><p>The room is held for these dates and the guest is in your hotel directory.</p><button className="button button-primary" onClick={onClose}>Done</button></div></section></div>;
  return <div className="modal-backdrop" role="presentation" onMouseDown={event => { if (event.target === event.currentTarget) onClose(); }}><section className="reservation-modal" role="dialog" aria-modal="true" aria-labelledby="reservation-title"><button className="modal-close" onClick={onClose} aria-label="Close"><X size={18}/></button><div className="eyebrow">DIRECT BOOKING</div><h2 id="reservation-title">New reservation</h2><p className="modal-subtitle">Add the guest, choose a room and confirm the stay dates.</p><form action={action} className="reservation-form">
    <input type="hidden" name="organization_id" value={organizationId}/><input type="hidden" name="property_id" value={propertyId}/>
    <label>Guest full name<input name="guest_name" required minLength={2} autoFocus placeholder="e.g. Emeka Okafor"/></label>
    <div className="reservation-form-row"><label>Phone<input name="guest_phone" type="tel" placeholder="+234 800 000 0000"/></label><label>Email<input name="guest_email" type="email" placeholder="guest@example.com"/></label></div>
    <div className="reservation-form-row"><label>Arrival<input name="arrival_date" type="date" min={today} value={arrival} onChange={event => { const value = event.target.value; setArrival(value); if (value >= departure) setDeparture(new Date(new Date(`${value}T12:00:00`).getTime() + 86400000).toLocaleDateString("en-CA", { timeZone: "Africa/Lagos" })); }} required/></label><label>Departure<input name="departure_date" type="date" min={arrival || tomorrow} value={departure} onChange={event => setDeparture(event.target.value)} required/></label></div>
    <div className="reservation-form-row"><label>Room<select name="room_id" value={roomId} onChange={event => setRoomId(event.target.value)} required>{availableRooms.length ? availableRooms.map(room => <option key={room.id} value={room.id}>{room.number} · {room.type}</option>) : <option value="">No rooms available for these dates</option>}</select></label><label>Adults<input name="adults" type="number" min={1} max={12} defaultValue={1} required/></label></div>
    {availabilityError && <p className="form-error" role="alert">Could not check date availability. Try again or contact your manager.</p>}
    <input type="hidden" name="pricing_mode" value={pricingMode}/>
    <input type="hidden" name="expected_quote" value={JSON.stringify(quote.map(night => ({ service_date: night.service_date, standard_rate_kobo: night.standard_rate_kobo })))}/>
    {canApprovePricing && <label>Pricing<select value={pricingMode} onChange={event => setPricingMode(event.target.value)}><option value="standard">Scheduled standard rates</option><option value="override">Approve a fixed nightly rate</option></select></label>}
    {pricingMode === "override" && <label>Approved rate per night (₦)<input name="nightly_rate" type="number" min={0} step="0.01" value={nightlyRate} onChange={event => setNightlyRate(event.target.value)} required/><span className="optional">Enter zero for a complimentary stay. This rate applies to every night.</span></label>}
    {quoteLoading && <p role="status">Loading nightly quote…</p>}
    {quoteError && <p className="form-error" role="alert">{quoteError}<button type="button" className="text-button" onClick={() => setQuoteRevision(value => value + 1)}>Retry</button></p>}
    {quote.length > 0 && <div className="nightly-quote"><div className="table-wrap"><table><thead><tr><th>Night</th><th>Standard rate</th><th>Agreed rate</th></tr></thead><tbody>{quote.map(night => <tr key={night.service_date}><td>{night.service_date}<small className="sub-cell">{night.rate_name}</small></td><td>{money(night.standard_rate_kobo)}</td><td>{money(pricingMode === "override" ? Number(nightlyRate) * 100 : night.standard_rate_kobo)}</td></tr>)}</tbody></table></div><p><strong>Quoted room total: {money(quotedTotal)}</strong></p><p className="optional">Room charges post after each completed night. This quote excludes extras.</p></div>}
    {canApprovePricing && pricingOverride && <label>Approval reason<textarea name="pricing_reason" required minLength={5} maxLength={500} rows={2} placeholder="Why is this rate approved?"/><span className="optional">Your approval and each standard nightly rate will be recorded.</span></label>}
    {!canApprovePricing && pricingOverride && <p className="form-error">An owner or manager must approve a complimentary night.</p>}
    <label>Stay notes <span className="optional">Optional</span><textarea name="notes" rows={2} maxLength={500} placeholder="Arrival time, preferences, or other notes"/></label>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}
    <div className="modal-actions"><button type="button" className="button" onClick={onClose}>Cancel</button><button className="button button-primary" disabled={pending || availabilityLoading || quoteLoading || !quote.length || !availableRooms.length || Boolean(availabilityError) || Boolean(quoteError) || (!canApprovePricing && pricingOverride)}>{pending ? <LoaderCircle className="spin" size={15}/> : null}Confirm reservation</button></div>
  </form></section></div>;
}
