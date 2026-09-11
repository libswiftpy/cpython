import Testing
@testable import Python

@MainActor
@Suite(.serialized)
struct RandomTests {
    init() throws { try PyRuntime.initialize() }

    @Test func bundledRandomSupportsSeedsAndState() throws {
        try PyRuntime.run("""
        import random
        for seed in [42, 'example', b'example', bytearray(b'example')]:
            first = random.Random(seed)
            second = random.Random(seed)
            assert [first.random() for _ in range(10)] == [second.random() for _ in range(10)]
        rng = random.Random(42)
        state = rng.getstate()
        expected = rng.getrandbits(100)
        rng.setstate(state)
        assert rng.getrandbits(100) == expected
        """)
    }

    @Test func bundledRandomSupportsCommonOperations() throws {
        try PyRuntime.run("""
        import random
        import math
        rng = random.Random(42)
        assert 1 <= rng.randint(1, 6) <= 6
        assert rng.randrange(0, 20, 2) in range(0, 20, 2)
        assert rng.choice(['a', 'b']) in ['a', 'b']
        assert rng.choices(['a', 'b'], weights=[0, 1], k=3) == ['b', 'b', 'b']
        assert len(set(rng.sample(range(100), 5))) == 5
        items = list(range(10))
        rng.shuffle(items)
        assert sorted(items) == list(range(10))
        assert 2 <= rng.uniform(2, 3) <= 3
        assert math.isfinite(rng.gauss(0, 1))
        assert len(rng.randbytes(8)) == 8
        assert 0 <= random.SystemRandom().random() < 1
        """)
    }
}
