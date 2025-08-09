import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter, Routes, Route } from "react-router-dom";
import App from "./App.jsx";
import CareerHome from "./pages/CareerHome.jsx";
import Attributes from "./pages/Attributes.jsx";
import Training from "./pages/Training.jsx";
import HSStandings from "./pages/HSStandings.jsx";
import HSBracket from "./pages/Training.jsx";
import HSRankings from "./pages/HSBracket.jsx";
import RosterDepth from "./pages/RosterDepth.jsx";
import Recruiting from "./pages/Recruiting.jsx";

ReactDOM.createRoot(document.getElementById("root")).render(
  <BrowserRouter>
    <Routes>
      <Route path="/" element={<App />}>
        <Route index element={<CareerHome />} />
        <Route path="attributes" element={<Attributes />} />
        <Route path="training" element={<Training />} />
        <Route path="hs/standings" element={<HSStandings />} />
        <Route path="hs/bracket" element={<HSBracket />} />
        <Route path="hs/rankings" element={<HSRankings />} />
        <Route path="hs/roster" element={<RosterDepth />} />
        <Route path="recruiting" element={<Recruiting />} />
      </Route>
    </Routes>
  </BrowserRouter>
);
