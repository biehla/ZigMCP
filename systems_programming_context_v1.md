---
document_type: ai_reference_context
topic: data_driven_programming_for_systems_software
version: 1
source_research_date: 2026-11-09
derived_from: systems_paradigms_v1.md
source_library_id: libfile_555d0c61927c8191a9397b25b39d42fb
transformation: condensed_and_restructured_without_new_research
evidence_scope: selective_narrative_review_not_systematic_review
---

# Data-driven systems programming: AI reference context

## CONTEXT — Scope and interpretation

Purpose: supply reusable background for architecture discussion, implementation planning, and technical review. This document is reference material, not a mandate to refactor software or adopt a particular architecture. Project requirements and measured behaviour determine applicability.

Scope: operating systems, drivers, networking, compilers, storage engines, embedded pipelines, and systems runtimes. Merely processing data, using a database, or generating code with an AI assistant does not identify one of the approaches below.

Evidence labels:

- **FACT:** a documented mechanism; source IDs follow the claim.
- **RESULT:** a study-specific empirical finding; retain its conditions.
- **SYNTHESIS:** the report’s classification or interpretation, not a standard taxonomy.
- **GUIDANCE:** an engineering recommendation requiring project-specific validation.

Source IDs S01–S24 map to the source registry at the end. Candidate uses and evaluation checks in the concept records are GUIDANCE unless labelled otherwise. No benchmark was rerun and no implementation was tested for this document. The original report used direct web research; the requested deep-research skill was unavailable. Documentation is not a guarantee of current API compatibility or independent proof of superiority.

## CORE — Essential distinctions

**SYNTHESIS:** “Data-driven” is an umbrella covering different decisions made explicit in data representations. These approaches can coexist; they are not mutually exclusive replacements for imperative or object-oriented code.

| Concept ID | Approach | What data controls |
|---|---|---|
| P01 | Table/configuration driven | Behaviour within an engine’s supported operations |
| P02 | Pattern–action | Selection of actions for matching input |
| P03 | Data-oriented design | Physical representation and transformations |
| P04 | Entity–component–system (ECS) | Composition and query-based processing |
| P05 | Declarative/relational | Derived relationships and results |
| P06 | Dataflow/incremental | Dependencies, progress, and propagation of changes |
| P07 | Schema generation/staged compilation | Generated implementation and binding time |
| P08 | Programmable infrastructure | Constrained extension of processing behaviour |
| P09 | Event/descriptor driven | Work submission and completion handling |
| P10 | Profile-guided optimisation (PGO) | Compilation choices informed by execution profiles |
| P11 | Learned indexes | Search guidance informed by data distributions |
| P12 | Learned runtime policies | Allocation or scheduling decisions |

P04 and P08–P12 include architectural patterns and optimisation techniques, not exclusively formal programming paradigms. P10–P12 expand the original report’s combined empirical/learned-optimisation category.

## P01 — Table- and configuration-driven behaviour

- **FACT:** Linux Devicetree describes hardware for the operating system, decoupling machine-specific information from board/driver code [S01].
- Mechanism: a stable engine interprets descriptions, parameters, or action tables.
- Candidate use: hardware variants, protocol policies, explicit state transitions.
- Illustrative schema: `(state, event, guard, action, next_state)`; this is a hypothetical design, not a reported implementation.
- Boundary: configuration can select supported operations; new operation semantics can require new code.
- Checks: schema compatibility, invalid entries, conflicting rules, defaults, safe publication, rollback.

## P02 — Pattern–action programming

- **FACT:** AWK combines patterns with actions; actions may contain imperative control statements [S05].
- Candidate use: record/stream inspection, instrumentation, message selection.
- Boundary: matching input does not necessarily imply a state machine, relational fixed point, or asynchronous execution model.
- Checks: multiple matches, execution order, conflicting actions, explicit default behaviour.

## P03 — Data-oriented design

- **FACT:** Fabian emphasises data, transformations, workload characteristics, and the executing machine [S15]. DPDK guidance includes memory pools, per-core data, alignment, and NUMA-local allocation [S06].
- Candidate use: memory-intensive loops, bulk processing, repeated access to subsets of records.
- Hypothesis: structure-of-arrays may help field-wise scans; array-of-structures may suit whole-record access. Neither is universally superior.
- Checks: actual field access, ownership, lifetime, shared writes, allocation, conversion costs, target hardware.
- Boundary: data-oriented layout is distinct from configuration-driven behaviour and does not require machine learning.

## P04 — Entity–component–system architecture

- **FACT:** Flecs groups matching component sets into archetypes and supports queries that match and cache groups [S16].
- Candidate use: many objects processed by component combinations.
- Checks: query frequency, component combinations, structural mutation rate, reorganisation cost.
- Boundary: ECS does not inherently guarantee locality improvements, parallel safety, Datalog semantics, or distributed consistency.

## P05 — Declarative and relational programming

- **FACT:** Soufflé represents analysis input as facts and analysis specifications as rules, generating parallel C++ through intermediate representations [S07]. P2 compiles Network Datalog and uses a dataflow engine for network behaviour and state [S08].
- Candidate use: recursive graph relationships, static analysis, relational policy.
- Checks: input abstraction correctness, rule semantics, memory use, evaluation cost.
- Boundary: concise rules shift work to the engine; fewer handwritten lines do not establish lower total cost or correctness.

## P06 — Dataflow and incremental computation

- **FACT — SDF:** predetermined token production/consumption rates enable static scheduling for suitable signal-processing graphs [S09].
- **FACT — Timely:** Naiad supports cyclic data-parallel computation with logical timestamps and progress coordination [S03].
- **FACT — Differential:** differential computation extends incremental maintenance to nested iteration [S10].
- Candidate use: SDF for sufficiently regular pipelines; timely/differential computation for iterative or changing state.
- Checks: rates, topology, execution time, buffering, retained state, update propagation cost.
- Boundary: static scheduling is not a deadline proof; incremental maintenance does not guarantee cheap updates; logical timestamps are not necessarily wall-clock deadlines.

## P07 — Schema-driven generation and staged compilation

- **FACT:** TableGen factors domain descriptions into records processed by code-generation backends [S02]. Halide separates algorithm specification from scheduling choices such as tiling, storage, vectorisation, and parallelism [S11].
- Candidate use: repetitive compiler descriptions; computations with multiple implementation schedules.
- Checks: specification, generator/compiler, generated artifacts, tool versions, reproducibility.
- Boundary: declarative descriptions need not be interpreted on the hot path. Decide explicitly which choices bind at build time, startup, or runtime.

## P08 — Programmable infrastructure

- **FACT:** P4 separates describing packet-processing functionality from populating forwarding rules [S17]. The eBPF verifier tracks register/stack states and checks access conditions [S18].
- Candidate use: constrained infrastructure extension through a supported target interface.
- Checks: input validity, admission rules, application policy correctness, resource/performance bounds.
- Boundary: eBPF programs are executable code, not ordinary configuration; verifier acceptance is not proof of application correctness or timing. P4 and eBPF are different execution mechanisms.

## P09 — Event- and descriptor-driven execution

- **FACT:** io_uring represents operations through shared submission queues and reports results through completion queues; shared queue state requires correct memory ordering [S12].
- Candidate use: many outstanding I/O operations.
- Checks: buffer ownership/lifetime, request-completion matching, cancellation, shutdown, ordering, queue limits, backpressure.
- Boundary: asynchronous descriptors do not automatically provide a declarative dependency graph, zero-copy payload handling, or a latency improvement. Concurrency and queue depth require workload-specific evaluation.

## P10 — Profile-guided optimisation

- **FACT:** Clang uses sampled or instrumented execution profiles to inform compilation and warns about unrepresentative profiles [S04].
- Candidate use: software with measurable deployment workloads.
- Checks: representative profiling, independent evaluation traces, workload shifts, build reproducibility.
- Boundary: PGO does not require ML. A favourable training workload does not establish deployment benefit.

## P11 — Learned indexes

- **FACT:** learned indexing uses models to guide search while additional mechanisms preserve index semantics [S13]. PGM search returns an estimated position and a bounded candidate range [S19].
- **RESULT:** Marcus et al. demonstrate favourable comparisons for read-only, in-memory dense-array workloads; the study investigates caching, key size, and construction costs [S20].
- Candidate use: distributions and access patterns where prediction plus exact search is economical.
- Checks: exactness, bound validity, tuned conventional baseline, construction, updates, memory, changed distributions.
- Boundary: approximate internal prediction need not imply approximate lookup results. The cited benchmark does not establish superiority for all update-heavy or disk-bound workloads.

## P12 — Learned runtime policies

- **FACT:** Decima uses reinforcement learning for workload-specific scheduling [S14].
- **RESULT:** its 25-node Spark evaluation reported at least 21% improvement in average job completion time against evaluated hand-tuned heuristics and up to twofold improvement under high load [S14].
- Candidate use: complex resource decisions with measurable objectives and enforceable constraints.
- Checks: objective, fairness requirements, distribution shift, inference/retraining costs, constraint violations, fallback frequency.
- Boundary: the Decima result is not a universal scheduler speedup, fairness result, or hard real-time guarantee.

## GUARANTEES — Cross-cutting constraints

- **FACT:** batching can trade individual-packet latency for throughput in DPDK [S06]. **GUIDANCE:** report both; do not substitute throughput for deadline performance.
- **FACT:** RCU separates removal from reclamation so relevant readers can finish [S21]. **GUIDANCE:** atomic pointer replacement alone does not solve publication, consistency, and reclamation.
- **FACT:** safe Rust prevents data races but not all general race conditions [S22]. **GUIDANCE:** distinguish memory safety from correct event order.
- **FACT:** Bloom/CALM work identifies coordination-free consistency opportunities under relevant monotonicity conditions [S23]. **GUIDANCE:** do not generalise this to arbitrary distributed programs.
- **FACT:** ML systems can incur system-level debt through data dependencies, entanglement, feedback, and external changes [S24]. **GUIDANCE:** retain model/configuration versions, decision provenance, and a defined recovery path.
- **SYNTHESIS:** well-formed input, admitted execution, correct policy, memory safety, consistency, and bounded timing are distinct properties.

## SELECT — Conditional decision rules

All rules below are GUIDANCE; choose based on a diagnosed requirement, not terminology.

1. Repeated variants within fixed semantics → consider P01.
2. Input matching dominates control logic → consider P02.
3. Measured memory/access bottleneck → investigate P03; P04 only if composition/query organisation fits.
4. Recursive relationships dominate → consider P05.
5. Fixed data rates and constrained topology → investigate P06/SDF.
6. Repeated recomputation over changing inputs → compare P06/incremental with full recomputation, including retained state.
7. Duplicated domain descriptions → consider P07; choose binding time explicitly.
8. Infrastructure extension requirement → compare supported P08 targets and constraints.
9. Many pending I/O requests → consider P09 with explicit lifetimes and queue limits.
10. Representative execution measurements available → evaluate P10.
11. Search prediction potentially economical → compare P11 against tuned exact baselines.
12. Complex policy optimisation → consider P12 with separately enforced invariants and a measured fallback.

Hybrid design is permissible. Hypothetical example: validated policy descriptions → generated compact lookup state → data-oriented packet workers → telemetry-informed tuning. Concurrent replacement needs a suitable publication/reclamation protocol. This composition is a proposal, not an evaluated system.

## VERIFY — Implementation and evaluation protocol

The following protocol is GUIDANCE from the report:

1. Define semantics, exactness, permitted order, failure behaviour, memory limits, and deadlines.
2. Measure the current implementation and use a credible tuned baseline.
3. Separate tuning/training/profile workloads from independent evaluation workloads.
4. Unit-test components: parsers, matching, generated outputs, bounds, ownership, numerical behaviour.
5. Test subsystems, then integration: concurrent updates, cancellation, exhaustion, mode changes.
6. Test end to end on target hardware; record compiler options, topology, placement, workload, background conditions.
7. Report throughput, latency quantiles, memory, errors, preparation/update costs, repeated-trial uncertainty.
8. For learned components, add shifts, constraint violations, fallback, inference, and maintenance costs.

Conceptual lifecycle accounting: execution savings minus preparation, conversion, validation, update, coordination, and model/profile maintenance costs. Use consistent units or report costs separately. Simplified amortisation count is C/s for preparation time C and positive stable per-execution saving s; this formula is not evidence that the assumptions hold.

## LIMITS — Preserve when summarising or recommending

- This is a selective narrative synthesis, not a systematic review, standard taxonomy, or benchmark ranking.
- Documentation establishes mechanisms, not universal efficiency or defect reductions.
- Historical measurements retain their original workloads, baselines, and hardware scope.
- No new tests, implementations, formal guarantees, or current-version compatibility checks were performed.
- Keep hypotheses and GUIDANCE distinct from FACT and RESULT.
- Check target versions before implementation; cite exact source documents for technical claims.
- Research gaps: comparable benchmarks, timing-aware compilation, safe schema evolution, robust learned components, decision provenance, joint layout/scheduling optimisation, and measured maintenance costs.

## SOURCES — Registry

- **S01** — Likely, G. **Linux and the Devicetree.** Linux Kernel documentation. [Source](https://cdn.kernel.org/doc/html/latest/devicetree/usage-model.html).
- **S02** — LLVM Project. **TableGen Overview.** Official documentation. [Source](https://www.llvm.org/docs/TableGen/index.html).
- **S03** — Murray, D. G., McSherry, F., Isaacs, R., Isard, M., Barham, P., & Abadi, M. (2013). **Naiad: A Timely Dataflow System.** ACM Symposium on Operating Systems Principles. [Publication and abstract](https://www.microsoft.com/en-us/research/publication/naiad-a-timely-dataflow-system-2/).
- **S04** — LLVM Project. **Clang Compiler User’s Manual: Profile Guided Optimization.** Official documentation. [Source](https://clang.llvm.org/docs/UsersManual.html#profile-guided-optimization).
- **S05** — Free Software Foundation. **Patterns and Actions; Pattern Action Summary.** GNU Awk User’s Guide. [Source](https://www.gnu.org/software/gawk/manual/html_node/Pattern-Action-Summary.html).
- **S06** — DPDK Project. **Writing Efficient Code.** Data Plane Development Kit 21.11.9 documentation. [Source](https://doc.dpdk.org/guides-21.11/prog_guide/writing_efficient_code.html).
- **S07** — Jordan, H., Scholz, B., & Subotić, P. (2016). **Soufflé: On Synthesis of Program Analyzers.** Computer Aided Verification. [Paper](https://souffle-lang.github.io/pdf/cav16.pdf).
- **S08** — Loo, B. T. (2006). **The Design and Implementation of Declarative Networks.** Doctoral dissertation, University of California, Berkeley; Technical Report UCB/EECS-2006-177. [Source and full-text link](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2006/EECS-2006-177.html).
- **S09** — Lee, E. A., & Messerschmitt, D. G. (1987). **Static Scheduling of Synchronous Data Flow Programs for Digital Signal Processing.** IEEE Transactions on Computers, C-36(1), 24–35. [Author publication page](https://ptolemy.berkeley.edu/publications/papers/87/staticscheduling/).
- **S10** — McSherry, F., Murray, D. G., Isaacs, R., & Isard, M. (2013). **Differential Dataflow.** Conference on Innovative Data Systems Research. [Publication page](https://www.microsoft.com/en-us/research/publication/differential-dataflow/); [paper](https://www.microsoft.com/en-us/research/wp-content/uploads/2013/01/differentialdataflow.pdf).
- **S11** — Ragan-Kelley, J., Adams, A., Paris, S., Levoy, M., Amarasinghe, S., & Durand, F. (2012). **Decoupling Algorithms from Schedules for Easy Optimization of Image Processing Pipelines.** ACM Transactions on Graphics, 31(4). [Author publication page](https://people.csail.mit.edu/jrk/halide12/).
- **S12** — **io_uring(7): Asynchronous I/O Facility.** Linux manual page. [Source](https://man7.org/linux/man-pages/man7/io_uring.7.html).
- **S13** — Kraska, T., Beutel, A., Chi, E. H., Dean, J., & Polyzotis, N. (2018). **The Case for Learned Index Structures.** ACM SIGMOD. DOI: 10.1145/3183713.3196909. [Paper](https://www.cl.cam.ac.uk/~ey204/teaching/ACS/R244_2018_2019/papers/Kraska_SIGMOD_2018.pdf).
- **S14** — Mao, H., Schwarzkopf, M., Venkatakrishnan, S. B., Meng, Z., & Alizadeh, M. (2019). **Learning Scheduling Algorithms for Data Processing Clusters.** ACM SIGCOMM, 270–288. DOI: 10.1145/3341302.3342080. [Paper](https://web.mit.edu/decima/content/sigcomm-2019.pdf).
- **S15** — Fabian, R. (2018). **Data-Oriented Design.** Author-published book, online reduced edition. [Relevant chapter](https://www.dataorienteddesign.com/dodbook/node2.html).
- **S16** — Flecs Project. **Queries.** Official documentation. [Source](https://www.flecs.dev/flecs/Queries.html).
- **S17** — Bosshart, P., et al. (2014). **P4: Programming Protocol-Independent Packet Processors.** ACM SIGCOMM Computer Communication Review. [Paper](https://www.cs.princeton.edu/~jrex/papers/P4-ccr14.pdf).
- **S18** — Linux Kernel Project. **eBPF Verifier.** Official documentation. [Source](https://cdn.kernel.org/doc/html/latest/bpf/verifier.html).
- **S19** — PGM-index Project. **C++ Reference.** Official implementation documentation. [Source](https://pgm.di.unipi.it/docs/cpp-reference/).
- **S20** — Marcus, R., Kipf, A., van Renen, A., Stoian, M., Misra, S., Kemper, A., Neumann, T., & Kraska, T. (2020). **Benchmarking Learned Indexes.** Research paper, arXiv:2006.12804. [Paper record and text](https://arxiv.org/abs/2006.12804).
- **S21** — Linux Kernel Project. **What Is RCU? “Read, Copy, Update.”** Official documentation. [Source](https://docs.kernel.org/RCU/whatisRCU.html).
- **S22** — Rust Project. **Data Races and Race Conditions.** The Rustonomicon. [Source](https://doc.rust-lang.org/nomicon/races.html).
- **S23** — Conway, N., Marczak, W., Alvaro, P., Hellerstein, J. M., & Maier, D. (2012). **Logic and Lattices for Distributed Programming.** University of California, Berkeley, Technical Report UCB/EECS-2012-167. [Source and full-text link](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2012/EECS-2012-167.html).
- **S24** — Sculley, D., et al. (2015). **Hidden Technical Debt in Machine Learning Systems.** Advances in Neural Information Processing Systems 28. [Paper](https://proceedings.neurips.cc/paper/2015/file/86df7dcfd896fcaf2674f757a2463eba-Paper.pdf).
