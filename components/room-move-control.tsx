"use client";
import { useActionState } from "react";
import { LoaderCircle, MoveRight } from "lucide-react";
import { moveReservationAction, type ActionState } from "@/app/actions";
export function RoomMoveControl({ reservationId, rooms }: { reservationId: string; rooms: { id: string; number: string }[] }) {
  const [state, action, pending] = useActionState(moveReservationAction, {} as ActionState);
  if (!rooms.length) return null;
  return <form action={action} className="room-move-form"><input type="hidden" name="reservation_id" value={reservationId}/><select name="room_id" aria-label="Move guest to room" defaultValue=""><option value="" disabled>Move to room…</option>{rooms.map(room => <option value={room.id} key={room.id}>{room.number}</option>)}</select><button className="button" disabled={pending}>{pending ? <LoaderCircle size={13} className="spin"/> : <MoveRight size={13}/>}Move</button>{state.error && <span className="form-error">{state.error}</span>}{state.success && <span className="admin-success">Moved</span>}</form>;
}
