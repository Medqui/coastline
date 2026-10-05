"use client";

import { useActionState } from "react";
import { Check, LoaderCircle } from "lucide-react";
import { updateRoomHousekeepingAction, type ActionState } from "@/app/actions";

export function RoomStatusAction({ roomId, status }: { roomId: string; status: string }) {
  const [state, action, pending] = useActionState(updateRoomHousekeepingAction, {} as ActionState);
  return <form action={action} className="room-status-action">
    <input type="hidden" name="room_id" value={roomId}/>
    <select name="status" defaultValue={status} aria-label="Housekeeping status">
      <option value="dirty">Dirty</option><option value="clean">Clean</option><option value="inspected">Inspected</option><option value="out_of_order">Out of order</option>
    </select>
    <button className="button" disabled={pending}>{pending ? <LoaderCircle className="spin" size={13}/> : state.success ? <Check size={13}/> : null}{state.success ? "Saved" : "Update"}</button>
    {state.error && <small role="alert">{state.error}</small>}
  </form>;
}
