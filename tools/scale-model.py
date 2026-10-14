"""Reproducible, optimistic offline model. Never creates network connections.

The million-node graph measures only reachability of one tiny message in a
fixed random overlay. It is NOT a load test of FarvaharTrends/HyperDHT. Load and
finite cache limits are calculated separately; the graph omits those costs.
"""
import json
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.local-only/scale-audit'
OUT.mkdir(parents=True, exist_ok=True)
measured = json.loads((OUT / 'measured.json').read_text(encoding='utf-8'))
rng = np.random.default_rng(20261013)
population, degree = 1_000_000, 8
neighbors = np.empty((population, degree), dtype=np.uint32)
cycles = []
# Four independently shuffled reciprocal cycles: at most eight total neighbors
# per phone. This respects the connection cap instead of giving each phone
# eight outgoing links plus unbounded incoming links.
for pair in range(degree // 2):
    order = rng.permutation(population).astype(np.uint32)
    following = np.roll(order, -1)
    neighbors[order, pair*2] = following
    neighbors[following, pair*2+1] = order
    cycles.append((order, following))
scenarios = []
for name, active_fraction, success, seeds in [
    ('mostly active, many usable paths', .9, .8, 10),
    ('half active, half of paths usable', .5, .5, 10),
    ('sparse background availability', .2, .5, 10),
    ('no external ingress during partition', .5, .5, 0),
]:
    active = rng.random(population) < active_fraction
    eligible = np.flatnonzero(active)
    usable = np.zeros((population, degree), dtype=bool)
    for pair, (order, following) in enumerate(cycles):
        links = rng.random(population) < success
        usable[order, pair*2] = links
        usable[following, pair*2+1] = links
    reached = np.zeros(population, dtype=bool)
    frontier = rng.choice(eligible, size=seeds, replace=False)
    reached[frontier] = True
    counts = [int(reached.sum())]
    for step in range(100):  # idealized 3 seconds/hop, at most five minutes
        if not len(frontier): break
        next_ids = neighbors[frontier][usable[frontier]]
        next_ids = next_ids[active[next_ids] & ~reached[next_ids]]
        frontier = np.unique(next_ids)
        reached[frontier] = True
        counts.append(int(reached.sum()))
    scenarios.append(dict(name=name, activeFraction=active_fraction,
        pathSuccess=success, ingressSeeds=seeds, reached=int(reached.sum()),
        active=int(active.sum()), propagationRounds=len(counts)-1,
        idealSeconds=(len(counts)-1)*3, countsByRound=counts))

loads = []
for publishers, posts_per_publisher_per_minute in [(100, .1), (1000, 1), (20000, 1), (1000000, .1)]:
    per_minute = publishers * posts_per_publisher_per_minute
    for kind in ['ordinary', 'editor']:
        size = measured[kind + 'BulletinFrameBytes']
        fanout = 7
        loads.append(dict(publishers=publishers, perPublisherPerMinute=posts_per_publisher_per_minute,
            newsType=kind, globalPostsPerMinute=per_minute,
            bulletinBytesPerMinutePerRelay=per_minute*size*fanout,
            egressBudgetBytesPerMinute=4*1024*1024,
            budgetDemandRatio=round(per_minute*size*fanout/(4*1024*1024), 3),
            perLinkBudgetDemandRatio=round(per_minute*size/(512*1024), 3),
            globalFrameBudgetDemandRatio=round(per_minute*fanout/2400, 3),
            global256NewsCacheSeconds=round(256*60/per_minute, 3),
            optimisticPostsPerMinuteBudget=round(min(4*1024*1024/(size*fanout),
                512*1024/size, 2400/fanout, 600), 2)))
result = dict(kind='offline model, not measured nationwide delivery', seed=20261013,
    population=population, degree=degree, graphScenarios=scenarios, loadScenarios=loads,
    assumptions=['fixed random topology', 'no correlated provider partitions', 'all edges immediately known',
        '3 seconds per hop', 'one tiny message', 'graph ignores CPU, rate budgets, cache loss and radio sleep',
        'load includes only bulletin frames; discovery, inventories, policies, images and overhead add cost',
        'uniform global all-channel forwarding; seven outgoing copies of each received post'])
(OUT/'model.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
print(json.dumps({k: v for k, v in result.items() if k != 'assumptions'}, indent=2))
