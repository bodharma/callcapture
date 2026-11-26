import { Link } from "react-router";

export function NotFound() {
  return (
    <main className="not-found">
      <h1>Not found</h1>
      <p>There is nothing at this address.</p>
      <Link to="/sessions">Back to sessions</Link>
    </main>
  );
}
