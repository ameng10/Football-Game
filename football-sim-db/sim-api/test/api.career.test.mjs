import request from 'supertest';
import { strict as assert } from 'assert';
import app from '../../src/app.mjs'; // Adjust path if needed

describe('Career API', function () {
    let server;

    before(function (done) {
        server = app.listen(0, done);
    });

    after(function (done) {
        server.close(done);
    });

    it('should create a new career', async function () {
        const res = await request(server)
            .post('/api/career')
            .send({ name: 'Test Coach', team: 'Test Team' })
            .expect(201);

        assert.ok(res.body.id);
        assert.equal(res.body.name, 'Test Coach');
        assert.equal(res.body.team, 'Test Team');
    });

    it('should get all careers', async function () {
        const res = await request(server)
            .get('/api/career')
            .expect(200);

        assert.ok(Array.isArray(res.body));
    });

    it('should get a career by id', async function () {
        const createRes = await request(server)
            .post('/api/career')
            .send({ name: 'Coach2', team: 'Team2' })
            .expect(201);

        const id = createRes.body.id;

        const res = await request(server)
            .get(`/api/career/${id}`)
            .expect(200);

        assert.equal(res.body.id, id);
        assert.equal(res.body.name, 'Coach2');
        assert.equal(res.body.team, 'Team2');
    });

    it('should update a career', async function () {
        const createRes = await request(server)
            .post('/api/career')
            .send({ name: 'Coach3', team: 'Team3' })
            .expect(201);

        const id = createRes.body.id;

        const res = await request(server)
            .put(`/api/career/${id}`)
            .send({ name: 'Coach3 Updated', team: 'Team3' })
            .expect(200);

        assert.equal(res.body.name, 'Coach3 Updated');
    });

    it('should delete a career', async function () {
        const createRes = await request(server)
            .post('/api/career')
            .send({ name: 'Coach4', team: 'Team4' })
            .expect(201);

        const id = createRes.body.id;

        await request(server)
            .delete(`/api/career/${id}`)
            .expect(204);

        await request(server)
            .get(`/api/career/${id}`)
            .expect(404);
    });
});
