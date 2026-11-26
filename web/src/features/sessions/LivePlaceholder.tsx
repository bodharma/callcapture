import { Link, useParams } from "react-router";

/** `/sessions/:id/live`: the saved live map view arrives with the live panel work. */
export function LivePlaceholder() {
  const { id = "" } = useParams();
  return (
    <div className="detail">
      <h1 className="detail-title">Topic map</h1>
      <p className="empty">The live map view for past sessions isn't built yet.</p>
      <Link to={`/sessions/${encodeURIComponent(id)}`}>Back to the session</Link>
    </div>
  );
}
