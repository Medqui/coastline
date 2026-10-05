"use client";

import { useActionState } from "react";
import { ArrowRight, LoaderCircle } from "lucide-react";
import { setupHotelAction, type ActionState } from "@/app/actions";

const initialState: ActionState = {};
export function HotelSetupForm() {
  const [state, action, pending] = useActionState(setupHotelAction, initialState);
  return <form action={action} className="setup-form">
    <label>Hotel business name<input name="organization_name" required minLength={2} maxLength={120} placeholder="e.g. Seaview Hospitality Ltd"/></label>
    <label>First property name<input name="property_name" required minLength={2} maxLength={120} placeholder="e.g. Calabar Seaview Hotel"/></label>
    <label>Property address<input name="address" maxLength={240} placeholder="Street and area, Calabar"/></label>
    <div className="setup-form-row"><label>Number of rooms<input name="room_count" type="number" min={1} max={300} defaultValue={20} required/></label><label>Standard nightly rate (₦)<input name="standard_rate" type="number" min={0} step={100} defaultValue={45000} required/></label></div>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}
    <button className="button button-primary setup-submit" disabled={pending}>{pending ? <LoaderCircle className="spin" size={16}/> : null}Create hotel workspace <ArrowRight size={16}/></button>
    <p className="setup-footnote">You’ll become the organization owner. Rooms start as dirty so they’re checked by housekeeping before selling.</p>
  </form>;
}
