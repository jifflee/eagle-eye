import { Routes, Route } from "react-router-dom";
import Layout from "./components/Layout/Layout";
import HomePage from "./pages/HomePage";
import GraphPage from "./pages/GraphPage";
import SearchPage from "./pages/SearchPage";

export default function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route path="/" element={<HomePage />} />
        <Route path="/investigation/:id" element={<GraphPage />} />
        <Route path="/search" element={<SearchPage />} />
      </Route>
    </Routes>
  );
}
