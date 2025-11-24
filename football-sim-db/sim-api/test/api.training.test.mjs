import request from "supertest";
import app from "../src/server.mjs";

describe("Training API", () => {
  let saveId;

  beforeAll(async () => {
    // Create a new career save for testing
    const res = await request(app)
      .post("/api/career/hs/create")
      .send({ saveName: "Test Save", first: "Test", last: "Player", pos: "QB", stars: 3 });
    expect(res.body.ok).toBe(true);
    saveId = res.body.saveId;
  });

  it("should apply training allocations", async () => {
    const allocations = [
      { attribute: "speed", delta: 2 },
      { attribute: "strength", delta: 1 }
    ];
    const res = await request(app)
      .post(`/api/career/${saveId}/training/apply`)
      .send({ allocations });
    expect(res.body.ok).toBe(true);
  });

  it("should play a minigame and award points", async () => {
    const res = await request(app)
      .post(`/api/career/${saveId}/minigame`)
      .send({ mode: "clicker", score: 100, simulate: false });
    expect(res.body.ok).toBe(true);
    expect(typeof res.body.points).toBe("number");
  });

  afterAll(async () => {
    // Clean up by deleting the test save
    await request(app)
      .post(`/api/career/${saveId}/delete`);
  });
});
