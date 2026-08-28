# Syncopade conductor wrapper起動回帰の改定 Todo

## 目的

`v0.1.1`で`syncopadeConductor.jl`をinclude-safeにした結果、
`scripts/run_conductor.jl`が定義をincludeするだけで正常終了し、conductorを起動しなくなった回帰を修正する。

conductor本体のinclude-safe contractは維持し、実行用wrapperが`main()`を明示的に1回だけ呼ぶ構造へ直す。
修正版は既存tagを動かさず、patch release `v0.1.2`として公開する。

## 現在確認できている事実

- `v0.1.1` / commit `c976174507a9c122b4b62a7059b96156e3ab4db2`がcurrent releaseである。
- `07dab014cbeb05b545aebc31e111063b74af1f61`で`syncopadeConductor.jl`末尾へ`PROGRAM_FILE` guardを追加した。
- `julia syncopadeConductor.jl`ではguardが真となり、従来どおり`main()`を呼ぶ。
- `scripts/run_conductor.jl`は`syncopadeConductor.jl`をincludeするだけで、include後に`main()`を呼んでいない。
- そのためwrapperはerrorを出さずexit code `0`で終了し、conductor listenerを作らない。
- `test/unit_conductor_queue.jl`はinclude時にconductorを起動しない現在のcontractによって正常終了できる。
- repositoryの`logs/conductor_events.csv`には先生の既存dirty差分がある。改定作業ではbyte単位で維持し、stageしない。

## 修正境界

### 変更対象

- `scripts/run_conductor.jl`
- `docs/TESTING.md`
- conductor wrapperのprocess-level regression test
- `Project.toml`（release Stepだけ）
- このTodoの実施記録

### 変更しない対象

- `syncopadeConductor.jl`の`PROGRAM_FILE` guard
- conductorのqueue、dispatch、retry、monitor、logging protocol
- server/clientの受付・通信protocol
- `v0.1.1` tagとその指示commit
- `logs/conductor_events.csv`

## 進行規則

- Todo作成はStep 1 Phase 1とは扱わない。
- B進行では先生の1回のStep指示に対してPhase 1→2→3→4を順番に実行し、Step完了後に停止する。
- 一度に実行するのは1 Step、各Step内でも1 Phaseずつ順番を守る。
- error、test failure、想定外のlistener、repository logへの追記があれば即停止する。
- Stepの追加・分割・順序変更・完了条件変更が必要なら、作業を進めずTodo全体の見直しを先生へ提案する。
- 各Step完了時は対象差分だけをcommit/pushし、`logs/conductor_events.csv`を除外する。
- `v0.1.1` tagは移動・削除せず、release成功時だけannotated tag `v0.1.2`を新規作成する。

---

## Step 1: wrapper起動回帰を再現し、launcher contractを固定する — 完了

### 目的

修正前`v0.1.1`でwrapperが即時終了する経路を、直接実行とinclude実行の違いに対応づけて記録する。

### 対象ファイル

- `scripts/run_conductor.jl`（読取のみ）
- `syncopadeConductor.jl`（読取のみ）
- `syncopadeClient.jl`（bind IP解決の読取のみ）
- このTodo

### 完了条件

- wrapperが`include`後に実行文を持たないことをsource上で確認する。
- wrapper processが短時間でexit code `0`となり、期待portにlistenerを残さないことを再現する。
- `syncopadeConductor.jl`直接実行では`PROGRAM_FILE` guardが真になることを確認する。
- 正本contractを「本体includeは定義のみ、直接実行とwrapper実行は`main()`を1回呼ぶ」と固定する。
- repository logに追記せず、processとlistenerをすべてcleanupする。

### 検証方法

1. `scripts/run_conductor.jl`と本体末尾のcall graphを照合する。
2. `SYNCOPADE_NODE_PROFILE=lan100`, `SYNCOPADE_WIRED_PREFIX=192.168.100.`を指定する。
3. `SYNCOPADE_CONDUCTOR_LOG`をrepository外の一時fileへ向ける。
4. wrapperをchild processとして起動し、短時間で終了することと`192.168.100.30:9030`がlistenしないことを確認する。
5. 実行前後で`logs/conductor_events.csv`のhashが一致することを確認する。

### Phase 1: 実装方針をまとめる — 完了

- Step 1ではproduction sourceを変更せず、`v0.1.1`のwrapper起動経路をそのまま観測する。
- source上で`wrapper -> include(syncopadeConductor.jl) -> PROGRAM_FILE guard=false -> main未呼出し`の経路を固定する。
- wrapperはchild processとして起動し、短時間でexit code `0`となることを回帰症状として記録する。
- lan100 profileとrepository外の一時logを使用し、実network上の既存conductorとrepository logを分離する。
- 起動前後に`192.168.100.30:9030`の空き、child process終了、repository log hashを確認する。
- wrapperが想定外に継続、listener生成、stderr出力、repository log変更を起こした場合は停止する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### Reproduction process

- command: `julia --project=. scripts/run_conductor.jl`
- environment:
  - `SYNCOPADE_NODE_PROFILE=lan100`
  - `SYNCOPADE_WIRED_PREFIX=192.168.100.`
  - `SYNCOPADE_CONDUCTOR_LOG=<repository外の一時file>`
- stdin: なし
- expected pre-fix exit: 2秒以内、exit code `0`
- expected stdout/stderr: ともに空
- expected listener: `192.168.100.30:9030`を生成しない
- expected temporary log: file自体を生成しない

#### Contract判定

- `scripts/run_conductor.jl`の実行中、include先の`PROGRAM_FILE`はwrapper pathであり、`syncopadeConductor.jl`の`@__FILE__`とは一致しない。
- したがって本体guardは`main()`を呼ばず、wrapper側に明示callがない現状ではtop-level評価後に正常終了する。
- 修正後contractは、本体includeでは起動せず、wrapper top-levelが`main()`を1回だけ所有することとする。

#### 副作用境界

- Step 1はsource、Git index、tag、remote refを変更しない。
- process、stdout、stderr、temporary log、receiptはrepository外に置く。
- repositoryの`logs/conductor_events.csv`は検証前後で同一hashを要求する。

### Phase 3: 実装する — 完了（source変更なし）

- Step 1は修正前evidenceの取得が目的なので、production/test sourceは変更していない。
- `scripts/run_conductor.jl`へ暫定call、sleep、debug logなどを追加していない。
- 変更はこのTodoのPhase 1–3記録だけである。

### Phase 4: テストまたは検証を行う — 完了

- baseline: commit `c976174507a9c122b4b62a7059b96156e3ab4db2`, tag `v0.1.1`
- result: `STEP1_RESULT=PASS_REPRODUCED_IMMEDIATE_EXIT`
- wrapper exit: 2秒以内、exit code `0`
- wrapper stdout/stderr: ともに0 byte
- `192.168.100.30:9030` listener: 生成なし
- temporary conductor log: 生成なし
- repository log hash: 検証前後とも`a680168272507f4049158b3f6a8df4fad98993b5`
- source確認: wrapperは本体include後に実行文を持たず、本体guardはinclude時に`main()`を呼ばない。
- raw evidence: `/tmp/syncopade-conductor-wrapper-step1.CudKF7/`
- receipt: `/tmp/syncopade-conductor-wrapper-step1.CudKF7/receipt.md`

#### Step 1結論

- `v0.1.1`の即時終了はerrorではなく、wrapperが`main()`のownershipを持たないために発生する正常終了である。
- 修正後も本体include-safe contractを維持し、wrapperだけが明示的に`main()`を1回呼ぶ。

---

## Step 2: wrapperからconductorを明示起動する — 完了

### 目的

include-safeな本体を維持したまま、公式wrapperから`main()`を明示的に1回呼び、従来の起動動作を回復する。

### 対象ファイル

- `scripts/run_conductor.jl`
- `docs/TESTING.md`
- このTodo

### 完了条件

- wrapperが本体include直後に`main()`を1回だけ呼ぶ。
- `syncopadeConductor.jl`のguardと`main()`本体は変更しない。
- docsに直接実行、wrapper実行、include-onlyの3 contractを明記する。
- wrapper processが期待portをlistenし、`LIST` requestへ有効なchecksum応答を返す。
- 明示終了後にprocess、listener、temporary log writerが残らない。

### 検証方法

1. lan100環境とrepository外の一時logを指定してwrapperを起動する。
2. child processが即時終了せず、`192.168.100.30:9030`をlistenすることを確認する。
3. `query_conductor_nodes("192.168.100.30"; conductor_port=9030)`が有効な`NODES`応答を返すことを確認する。
4. child processを明示終了し、exit状態とlistener消滅を確認する。
5. standard unit testとrepository log hashを確認する。

### Phase 1: 実装方針をまとめる — 完了

- `scripts/run_conductor.jl`は本体include直後に既存`main()`を明示的に1回呼ぶ。
- `syncopadeConductor.jl`の`PROGRAM_FILE` guardと`main()`本体は変更しない。
- wrapperに独自のbind、monitor loop、argument parsing、retry処理を複製しない。
- `docs/TESTING.md`へ直接実行、wrapper実行、library includeのownershipを明記する。
- Phase 4ではlan100と一時logを使い、process生存、9030 listener、`LIST`応答、cleanupを手動integrationで確認する。
- repository logのhashが変化した場合、または既存network endpointと競合した場合は停止する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### Wrapper entrypoint

- file: `scripts/run_conductor.jl`
- top-level sequence:
  1. `syncopadeConductor.jl`を絶対pathでincludeする。
  2. includeによって定義された`main()::Any`を1回呼ぶ。
- CLI引数: 追加しない。
- 正常時戻り: `main()`のmonitor loopが継続するため、外部終了要求までreturnしない。
- 例外: bind失敗、profile不正など既存`main()`以下の例外を握り潰さずprocess errorとする。

#### Process-level validation interface

- environment:
  - `SYNCOPADE_NODE_PROFILE=lan100`
  - `SYNCOPADE_WIRED_PREFIX=192.168.100.`
  - `SYNCOPADE_CONDUCTOR_LOG=<repository外の一時file>`
- expected endpoint: `192.168.100.30:9030`
- readiness: child process生存かつendpointへのTCP接続成功
- protocol probe: `query_conductor_nodes("192.168.100.30"; conductor_port=9030)`
- expected response: checksum検証可能な`NODES` payload
- shutdown: 検証processからchildへ`SIGTERM`を送り、process終了と9030 listener消滅を確認する。

#### 副作用

- conductorはlan100 profileのnodeへ既存`STATUS` probeを行う。
- `CONDUCTOR_START`等のlogは一時fileだけへ書き、repository logへ書かない。
- wrapper終了後にchild process、listener、log writer taskを残さない。

### Phase 3: 実装する — 完了

- `scripts/run_conductor.jl`のinclude直後に`main()`を1回追加した。
- `syncopadeConductor.jl`のguard、`main()`本体、queue、monitor、loggingは変更していない。
- `docs/TESTING.md`へ直接実行、wrapper実行、include-onlyのcontractを追記した。
- lan100のwrapper起動例をdocsへ追加した。

### Phase 4: テストまたは検証を行う — 完了

#### 確認できた事実

- wrapper child PID `8250`は即時終了せず、stdoutへ`Conductor server listening on 192.168.100.30:9030`を出力した。
- 一時conductor logが生成され、repository log hashは`a680168272507f4049158b3f6a8df4fad98993b5`のまま維持された。
- wrapper修正によってconductor processが起動するところまでは観測できた。

#### 停止理由

- readiness確認用Julia one-linerでglobal loop内の`payload`代入がsoft-scope扱いとなった。
- warning後もouter `payload`が`nothing`のまま残り、`conductor readiness timeout: nothing`を送出した。
- wrapperまたはconductorのerrorではなく、検証command側の実装errorである。
- C進行のerror停止規則に従い、`let` blockまたは関数化による補正再実行には進んでいない。

#### Cleanup

- childへ`SIGTERM`を送り、exit status `143`で終了した。
- cleanup後の`192.168.100.30:9030`: listenerなし。
- repository log: 追記なし。
- Step 2差分: 未commit、未push。
- raw evidence: `/tmp/syncopade-conductor-wrapper-step2.62M0XV/`
- receipt: `/tmp/syncopade-conductor-wrapper-step2.62M0XV/failure_receipt.md`

#### 再開条件

- readiness probeをglobal soft scopeのない関数または`let` blockへ閉じ込める。
- Phase 4をport preflightから再実行し、`LIST`応答、stderr評価、cleanupまで完了する。

#### 再開試行・最終検証

- readiness probeをlocal scopeを持つ`wait_for_list()`関数へ閉じ込めた。
- result: `STEP2_RESULT=PASS_WRAPPER_EXPLICIT_START`
- child PID: `8411`
- listener: `192.168.100.30:9030`
- protocol response: `NODES|`（checksum検証済みpayload）
- child process: protocol検証中も生存
- runtime stderr: 0 byte
- temporary log: `CONDUCTOR_START`を記録
- shutdown: `SIGTERM`、exit status `143`
- shutdown後stderr: Juliaの期待された`signal 15: Terminated` traceのみ
- cleanup後9030 listener: なし
- repository log hash: `a680168272507f4049158b3f6a8df4fad98993b5`のまま
- raw evidence: `/tmp/syncopade-conductor-wrapper-step2-resume.asC24P/`
- receipt: `/tmp/syncopade-conductor-wrapper-step2-resume.asC24P/receipt.md`

#### Step 2結論

- wrapperは本体include後に`main()`を明示呼出しし、conductorを正常起動できる。
- 本体のinclude-safe contractを戻さず、直接実行とwrapper実行の両ownershipを分離できた。

---

## Step 3: wrapper起動contractの自動回帰testを追加する — 完了

### 目的

wrapperが定義を読み込んで即時終了する回帰を、processとlistenerの両方で将来検出できるようにする。

### 対象ファイル

- 新規process-level integration test
- 必要な場合のみtest用helper
- `docs/TESTING.md`
- このTodo

### 完了条件

- testがrepositoryのJulia executableとwrapper pathを明示してchild processを起動する。
- test専用環境変数とrepository外の一時logを使用する。
- process生存、expected listener、`LIST`応答を独立に検証する。
- success、failureの両経路でchild processとlistenerをcleanupする。
- stderr、exit状態、temporary log pathをevidenceとして残す。
- test自身のincludeではnetwork接続やchild process起動を行わない。

### 検証方法

1. integration testをincludeし、副作用がないことを確認する。
2. lan100でintegration testを直接実行する。
3. wrapperが起動しないnegative fixtureまたは同等の局所検証で、testが回帰を検出できることを確認する。
4. success時に`LIST`応答、cleanup後のport解放、repository log hash一致を確認する。

### Phase 1: 実装方針をまとめる — 完了

- 新規`test/integration_conductor_wrapper_entrypoint.jl`へprocess-level検証を実装する。
- test file自体は`PROGRAM_FILE` guardを持ち、include時にchild processやlistenerを生成しない。
- `Base.julia_cmd()`、`addenv`、`run(...; wait=false)`でrepository wrapperをchild起動する。
- readinessはchild生存、9030 listener、checksum検証済み`LIST`応答の3条件で判定する。
- stdout/stderr、conductor log、negative fixtureは`mktempdir()`配下だけへ作成する。
- positive caseは修正済みwrapper、negative caseは本体をincludeするだけの一時scriptを使う。
- negative caseがexit code `0`かつlistenerなしとなることで、testが旧wrapper回帰を識別できることを確認する。
- 全process handle、file handle、listenerを`finally`でcleanupし、repository log bytesの前後一致を要求する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### Test entrypoint

- file: `test/integration_conductor_wrapper_entrypoint.jl`
- function: `wrapper_entrypoint_main(args::Vector{String}=ARGS)::Nothing`
- CLI入力:
  1. conductor IP（default `192.168.100.30`）
  2. conductor port（default `9030`）
  3. readiness/exit timeout seconds（default `5.0`）
- callbackやjob投入は行わず、`LIST` control requestだけを使用する。

#### Child launch helper

- input: script path、endpoint、timeout、case label、temporary directory
- command: `Base.julia_cmd()`へrepository projectとscript pathを渡す。
- environment: lan100 profile、wired prefix、case専用temporary conductor log
- output: process handle、stdout path、stderr path、log path
- runtime stderrはpositive readiness確定前に0 byteを要求する。

#### Positive判定

- timeout内に`query_conductor_nodes`がchecksum検証済み`NODES` payloadを返す。
- response後もchildが生存している。
- temporary logに`CONDUCTOR_START`が記録される。
- cleanupはまず`SIGTERM`を使用し、bounded wait内に終了しなければ`SIGKILL`へ昇格する。
- 最終`termsignal`はfallback未使用時`15`、使用時`9`を要求し、process終了とport解放を必須とする。
- SIGTERM後のJulia signal traceはruntime errorとは分離してevidenceへ残す。

#### Negative判定

- 一時scriptは`syncopadeConductor.jl`をincludeするだけで`main()`を呼ばない。
- timeout内にexit code `0`, `termsignal == 0`で終了する。
- stdout/stderr、temporary conductor logを生成せず、portを占有しない。

#### Cleanupと副作用

- signal送信後はbounded waitを使用し、例外時も生存childへ`SIGKILL`を送る。
- wait結果にかかわらず全IOを`finally`でcloseする。
- 起動前と全case終了後にportを一度bindして解放済みを確認する。
- repository logはbyte列をtest開始前後で比較する。
- test artifactsはrepository外の`mktempdir(cleanup=false)`へ残し、pathをstdoutへ出す。

### Phase 3: 実装する — 完了

- `test/integration_conductor_wrapper_entrypoint.jl`を追加した。
- positive caseはrepository wrapperをchild起動し、生存、`LIST`応答、runtime stderr、temporary logを検証する。
- negative caseは本体includeだけの一時scriptを生成し、exit code `0`、listenerなしを検証する。
- success cleanupは`SIGTERM`、failure cleanupは`SIGKILL`を使用し、いずれもwaitとIO closeを行う。
- repository logはtest開始前後のbyte列一致を要求する。
- test entrypointへ`PROGRAM_FILE` guardを付け、include時の副作用を抑止した。
- 再開時にchild terminationをbounded waitへ変更し、SIGTERM timeout時のSIGKILL fallbackを追加した。
- Step 4で判明したbuffer timing依存を除くため、positive stdoutのlistener文字列assertを削除した。
- 起動判定はprocess生存、checksum検証済み`LIST`、temporary `CONDUCTOR_START`、runtime stderr 0 byteで維持する。

### Phase 4: テストまたは検証を行う — 完了

#### 確認できた事実

- harness include check: `STEP3_HARNESS_INCLUDE_OK`
- artifact directory: `/var/folders/__/7pnh5g_x5qb2r25n4tgyyhww0000gn/T/syncopade-wrapper-entrypoint-HfZySQ`
- positive wrapperは`192.168.100.30:9030`をlistenし、一時logへ`CONDUCTOR_START`を記録した。
- repository log hashは`a680168272507f4049158b3f6a8df4fad98993b5`のまま維持された。

#### 停止理由

- harnessがpositive childへ`SIGTERM`を送信した後、childはsignal 15 traceをstderrへ出したが終了しなかった。
- `terminate_child!`の無期限`wait(process)`がreturnせず、test全体が30秒を超えて停止した。
- wrapper起動contractではなく、harnessのchild terminationを無期限waitにした設計errorである。
- C進行のerror停止規則に従い、bounded waitとSIGKILL fallbackへの修正再試行には進んでいない。

#### Cleanup

- test shell、harness、positive childを同一process group `8586`として`SIGKILL`で終了した。
- cleanup後の`192.168.100.30:9030`: listenerなし。
- repository log: 追記なし。
- Step 3差分: 未commit、未push。
- failure receipt: `/tmp/syncopade-conductor-wrapper-step3-failure-receipt.md`

#### 再開条件

- `terminate_child!`を「指定signal送信→bounded wait→timeout時SIGKILL→bounded wait」へ変更する。
- positive通常cleanupでもprocess終了を時間制限付きで保証し、Phase 4をpreflightから再実行する。

#### 再開試行・最終検証

- harness re-include: `STEP3_HARNESS_REINCLUDE_OK`
- result: `STEP3_RESULT=PASS_WRAPPER_ENTRYPOINT_REGRESSION`
- positive `LIST` payload: `NODES|`
- positive runtime stderr: 0 byte
- positive termination: `SIGTERM`, `termsignal=15`, SIGKILL fallback=`false`
- negative fixture: exit code `0`, `termsignal=0`
- negative stdout/stderr: 0 byte
- negative temporary conductor log: 生成なし
- final 9030 listener: なし
- repository log: byte列一致
- artifact directory: `/var/folders/__/7pnh5g_x5qb2r25n4tgyyhww0000gn/T/syncopade-wrapper-entrypoint-s9gmKH`
- receipt: `/var/folders/__/7pnh5g_x5qb2r25n4tgyyhww0000gn/T/syncopade-wrapper-entrypoint-s9gmKH/receipt.md`

#### Step 3結論

- 修正済みwrapperはprocess生存、listener、protocolの3条件を満たす。
- include-only negative fixtureは旧wrapperと同じ即時正常終了を示し、testが回帰を区別できる。
- success/failure cleanupは時間制限付きとなり、test自身が無期限停止しない。

#### stdout buffer依存除去後の再検証

- harness re-include: `STEP3_STDOUT_FIX_INCLUDE_OK`
- port preflight: `STEP3_STDOUT_FIX_PORT_PREFLIGHT_OK`
- result: `STEP3_RESULT=PASS_WRAPPER_ENTRYPOINT_REGRESSION`
- positive `LIST` payload: `NODES|`
- positive runtime stderr: 0 byte
- positive termination: `termsignal=9`, SIGKILL fallback=`true`
- negative fixture: exit code `0`, `termsignal=0`
- final 9030 listener: なし
- repository log: byte列一致
- artifact directory: `/var/folders/__/7pnh5g_x5qb2r25n4tgyyhww0000gn/T/syncopade-wrapper-entrypoint-j1jNmh`
- receipt: `/var/folders/__/7pnh5g_x5qb2r25n4tgyyhww0000gn/T/syncopade-wrapper-entrypoint-j1jNmh/receipt.md`

stdoutが0 byteでもprocess、protocol、temporary log、runtime stderrの正本条件でPASSし、buffer flush timingへの依存を除去できた。SIGTERMで終了しない場合もbounded wait後のSIGKILL fallbackで残留processとlistenerを残していない。

---

## Step 4: release前の回帰検証を行う — 完了

### 目的

wrapper修正がinclude-safe testability、conductor既存機能、server admission stateを壊していないことをrelease前に確認する。

### 対象ファイル

- `test/runtests.jl`
- `test/unit_client_protocol.jl`
- `test/unit_conductor_queue.jl`
- `test/unit_server_admission_state.jl`
- Step 3で追加したintegration test
- このTodo

### 完了条件

- conductor include checkが短時間で終了し、listenerを作らない。
- Client Protocol testが全件passする。
- Conductor Queue testが全件passする。
- Server Admission State testが全件passする。
- wrapper process integrationがpassする。
- stderrが空で、全process・listenerがcleanupされる。
- repository log hashが検証前後で一致する。

### 検証方法

1. `julia --project=. --threads=4 test/runtests.jl`を実行する。
2. `julia --project=. --threads=4 test/unit_server_admission_state.jl`を実行する。
3. Step 3のwrapper integration testを再実行する。
4. Git差分、stderr、process、port、log hashを照合する。

### Phase 1: 実装方針をまとめる — 完了

- Step 4はrelease candidateの検証専用とし、production/test sourceを変更しない。
- conductor include check、standard unit、server admission unit、wrapper integrationを直列実行する。
- 各commandのstdout/stderrをrepository外の同一artifact directoryへ分離保存する。
- wrapper integration以外のtestがnetwork conductorを起動しないことをportで確認する。
- 全stderr 0 byte、expected test count、wrapper regression marker、repository log byte列一致を要求する。
- いずれかのcommand error、件数不一致、stderr出力、listener残留、log変更で即停止する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### Regression command sequence

1. `julia --project=. -e 'include("syncopadeConductor.jl"); println("CONDUCTOR_INCLUDE_OK")'`
2. `julia --project=. --threads=4 test/runtests.jl`
3. `julia --project=. --threads=4 test/unit_server_admission_state.jl`
4. `julia --project=. test/integration_conductor_wrapper_entrypoint.jl 192.168.100.30 9030 5.0`

#### Expected results

- include marker: `CONDUCTOR_INCLUDE_OK`
- Client Protocol: `8 / 8 pass`
- Conductor Queue: `17 / 17 pass`
- Server Admission State: `13 / 13 pass`
- wrapper integration: `STEP3_RESULT=PASS_WRAPPER_ENTRYPOINT_REGRESSION`
- wrapper positive runtime stderr: 0 byte
- wrapper negative exit: code `0`, signal `0`
- all top-level command stderr: 0 byte

#### Environmentと副作用

- wrapper integrationはtest内でlan100とtemporary conductor logを設定する。
- command開始前に9030をbind可能とし、終了後も同じ条件を要求する。
- repository logは開始前bytesを保存し、全command後に一致させる。
- artifact directoryはrepository外へ作成し、stdout、stderr、receiptを保存する。

### Phase 3: 実装する — 完了（source変更なし）

- Step 4ではproduction/test sourceを変更していない。
- temporary runner、debug print、repository log redirectをrepository内へ追加していない。
- 変更はこのTodoのPhase 1–3記録だけである。

### Phase 4: テストまたは検証を行う — 完了

#### Passした検証

- conductor include: `CONDUCTOR_INCLUDE_OK`
- Client Protocol: `8 / 8 pass`
- Conductor Queue: `17 / 17 pass`
- Server Admission State: `13 / 13 pass`
- wrapper integration: `STEP3_RESULT=PASS_WRAPPER_ENTRYPOINT_REGRESSION`
- top-level command stderr: すべて0 byte
- wrapper positive runtime stderr: 0 byte
- wrapper negative exit: code `0`, signal `0`
- cleanup後9030 listener: なし

#### 停止理由

- `test/runtests.jl`のConductor Queue testが`SYNCOPADE_CONDUCTOR_LOG`未指定のためrepository既定logへ5行追記した。
- repository log hashが検証前`a680168272507f4049158b3f6a8df4fad98993b5`から変化し、Step 4完了条件を満たさなかった。
- wrapper integrationは自身の開始前後だけを比較するため、その前にstandard unitが行った追記を検出対象にできなかった。
- C進行のerror停止規則に従い、unit test用temporary logを指定した補正再実行には進んでいない。

#### Cleanupと監査

- 今回の21:52:24由来5行に加え、以前のrelease前testが21:25:55に残した5行も灯子由来と特定して除去した。
- 先生の既存4行だけを残し、repository logは`4 additions / 0 deletions`へ復元した。
- 復元後repository log Git blob ID: `b42bd0dc80df7523ceaaf760fa11e8f36fcaac1b`
- 復元後repository log content SHA-1: `528443adeeff16bfcd482c552458584d7a080e99`
- process残留: なし
- cleanup後9030 listener: なし
- Step 4差分: 未commit、未push。
- raw evidence: `/tmp/syncopade-conductor-wrapper-step4.KaQQe6/`
- receipt: `/tmp/syncopade-conductor-wrapper-step4.KaQQe6/failure_receipt.md`

#### 再開条件

- standard unit commandにも`SYNCOPADE_CONDUCTOR_LOG=<Step 4 artifact directory>/unit_conductor.csv`を指定する。
- repository log baselineを復元後Git blob ID `b42bd0dc80df7523ceaaf760fa11e8f36fcaac1b`、content SHA-1 `528443adeeff16bfcd482c552458584d7a080e99`として固定する。
- Phase 4をport preflightから再実行し、unit用temporary log生成とrepository log不変を確認する。

#### 再開試行1

- standard unitへ`SYNCOPADE_CONDUCTOR_LOG=/tmp/syncopade-conductor-wrapper-step4-resume.4ENCfQ/unit_conductor.csv`を指定した。
- Client Protocol: `8 / 8 pass`
- Conductor Queue: `17 / 17 pass`
- Server Admission State: `13 / 13 pass`
- unit用temporary log: headerと5 eventを記録
- repository log Git blob ID: `b42bd0dc80df7523ceaaf760fa11e8f36fcaac1b`のまま
- wrapper positive caseは`LIST`応答とtemporary `CONDUCTOR_START`まで成功した。
- wrapper testは終了後stdoutからlistener messageを探したが、redirect bufferがflushされずstdoutが0 byteだったため`@test` failureとなった。
- listenerとprotocolの成立は既に直接確認できており、stdout文字列は起動contractの必須条件ではない。
- top-level wrapper test stderrには上記`Test Failed`だけが記録された。
- cleanup後9030 listener: なし
- process残留: なし
- raw evidence: `/tmp/syncopade-conductor-wrapper-step4-resume.4ENCfQ/`
- failure receipt: `/tmp/syncopade-conductor-wrapper-step4-resume.4ENCfQ/failure_receipt.md`

#### 現在の再開条件

- Step 3 Phase 3へ戻り、buffer timingに依存するpositive stdout文字列assertを削除する。
- process生存、`LIST`成功、temporary `CONDUCTOR_START`、runtime stderr、cleanupを正本判定として維持する。
- Step 3 Phase 4を再実行して修正testをcommit/push後、Step 4 Phase 4を先頭から再実行する。

#### 再開試行2 — preflight停止

- artifact directory: `/tmp/syncopade-conductor-wrapper-step4-final.C6uvLO/`
- test command実行前のrepository log照合で停止した。
- 固定値`b42bd0dc80df7523ceaaf760fa11e8f36fcaac1b`はcontent SHA-1ではなくGit blob IDだった。
- `shasum`が返す現在のcontent SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`である。
- repository log差分は従来どおり`4 additions / 0 deletions`で、内容変更や新規追記はない。
- include、unit、admission、wrapper integrationは1本も実行していない。
- process起動、9030 listener、repository log追記はいずれも発生していない。
- failure receipt: `/tmp/syncopade-conductor-wrapper-step4-final.C6uvLO/failure_receipt.md`

#### 現在の再開条件

- Git blob IDとcontent SHA-1を区別し、preflightではcontent SHA-1 `528443adeeff16bfcd482c552458584d7a080e99`を照合する。
- `4 additions / 0 deletions`も併用し、先生の既存4行以外が変わっていないことを確認する。
- C進行のerror停止規則により、先生の再開指示まではStep 4 Phase 4を再実行しない。

#### 再開試行3 — 最終検証

- result: `STEP4_RESULT=PASS_RELEASE_REGRESSION`
- port preflight: `STEP4_PORT_PREFLIGHT_OK`
- conductor include: `CONDUCTOR_INCLUDE_OK`
- Client Protocol: `8 / 8 pass`
- Conductor Queue: `17 / 17 pass`
- Server Admission State: `13 / 13 pass`
- wrapper integration: `STEP3_RESULT=PASS_WRAPPER_ENTRYPOINT_REGRESSION`
- wrapper `LIST` payload: `NODES|`
- wrapper positive runtime stderr: 0 byte
- wrapper positive termination: `SIGTERM`, `termsignal=15`, SIGKILL fallback=`false`
- wrapper negative fixture: exit code `0`, `termsignal=0`
- top-level command stderr: 全6 fileが0 byte
- unit用temporary log: `TASK_REQUEUED`を含むheader + 5 events
- cleanup後9030 listener: なし
- repository log content SHA-1: `528443adeeff16bfcd482c552458584d7a080e99`のまま
- repository log Git blob ID: `b42bd0dc80df7523ceaaf760fa11e8f36fcaac1b`のまま
- repository log差分: `4 additions / 0 deletions`のまま
- artifact directory: `/tmp/syncopade-conductor-wrapper-step4-pass.kVJTkU/`
- receipt: `/tmp/syncopade-conductor-wrapper-step4-pass.kVJTkU/receipt.md`

#### Step 4結論

wrapper修正はinclude-safe contract、既存protocol/queue、server admission stateを壊していない。wrapper起動回帰testもprocess、protocol、temporary log、runtime stderr、negative include-only fixture、cleanupの全条件を満たした。repository既定logへtest由来の追記はない。

---

## Step 5: patch release `v0.1.2`を作成する

### 目的

wrapper起動回帰を修正した検証済みcommitを、既存tagを変更せず新しいpatch releaseとして固定する。

### 対象ファイル

- `Project.toml`
- このTodo
- Git commit / annotated tag / remote refs

### 完了条件

- `Project.toml`のversionが`0.1.2`となる。
- release前検証がversion変更後にもpassする。
- release commitがremote `master`へpushされる。
- annotated tag `v0.1.2`がrelease commitを指す。
- local/remote master、tag、peeled tag targetが一致する。
- `v0.1.1`は元のcommitを指したまま変化しない。
- `logs/conductor_events.csv`はstageもcommitもしない。

### 検証方法

1. `Pkg.project().version == v"0.1.2"`を確認する。
2. Step 4の標準unitとwrapper integrationを再実行する。
3. intended pathだけをstageし、cached diffとtest receiptを照合する。
4. release commitをpushする。
5. annotated tag `v0.1.2`を作成・pushし、`git ls-remote`とpeeled targetを照合する。
6. `v0.1.1`のlocal/remote targetが変更されていないことを確認する。

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手
