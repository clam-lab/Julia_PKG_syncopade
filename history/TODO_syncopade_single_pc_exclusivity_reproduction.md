# Syncopade 単一PC・単一server排他性 再現実験 Todo（履歴）

## 目的

`REQUEST_syncopade_node_execution_exclusivity.md` が報告するノード重複実行を、
調査対象revision `8ec26972020072a77926137462df0d65f81f8547` のまま、1台のPC上で再現する。

このPCが持つ `192.168.100.30` を利用し、conductor 1本、計算server 1本、
複数jobだけで実験系を構成する。現象の再現前には、既存の排他制御、dispatch、
server状態遷移ロジックを変更しない。

## 正本と判定条件

- 問題定義の正本: `REQUEST_syncopade_node_execution_exclusivity.md`
- 調査対象revision: `8ec26972020072a77926137462df0d65f81f8547`
- 単一資源modelの不変条件:

  \[
  n_{\mathrm{active}}(t) \in \{0,1\}
  \]

- 排他違反の成立条件:

  \[
  \max_t n_{\mathrm{active}}(t) \ge 2
  \]

- server側では、`busy` 中の2件目が `OK|STARTED|jobId` で受理されることも独立した違反evidenceとする。
- conductor側では、同一worker上のjob実行時間区間が重なることを重複dispatchのevidenceとする。
- 未再現は問題なしを意味しない。観測できなかった場合は「未再現」と記録する。

## 実験環境の固定条件

- 使用network profile: `lan100`
- local IP選択prefix: `192.168.100.`
- local server: `192.168.100.30:8030`
- local conductor: `192.168.100.30:9030`
- node候補は既存 `lan100` profileを使用する。
- conductor起動後、`SUBMIT`前にidle node一覧を検査する。
- idle nodeが `192.168.100.30:8030` の1件だけでなければfail-closedで実験を停止する。
- conductorの状態probeは許容するが、local server以外へのjob dispatchは許容しない。
- `SYNCOPADE_CONDUCTOR_LOG`を実験専用pathへ設定し、既存の`logs/conductor_events.csv`を変更しない。
- 各processのPID、起動command、stdout、stderr、終了状態をreceiptへ残す。
- conductor/server child processは、成功・失敗にかかわらず終了処理する。

## Step 1: lan100単一node実験系の事前検証 — 完了

### 目的

既存コードを変更せず、`192.168.100.30` 上でserverとconductorを起動する。
job投入前に、local serverだけがdispatch可能であることを確認する。

### 対象ファイル

- `syncopadeClient.jl`（読取り対象）
- `syncopadeNodeConfig.jl`（読取り対象）
- `syncopadeServer.jl`（既存entrypointを使用）
- `syncopadeConductor.jl`（既存entrypointを使用）
- `test/syncopadeBasicTestScript.jl`（既存fixtureを使用）
- 実験専用一時directoryの起動logとconductor event log

### 完了条件

- このPCが `192.168.100.30` を保持している。
- `8030/tcp` と `9030/tcp` が起動前に未使用である。
- serverが `192.168.100.30:8030`、conductorが `192.168.100.30:9030` へbindする。
- serverの`STATUS`応答が`idle`である。
- conductorのidle node一覧が `192.168.100.30:8030` の1件だけである。
- 単発jobがlocal serverへdispatchされ、callbackと`DONE`が対応する。
- 実験終了後、起動したlistenerが残らない。

### 検証方法

1. `ifconfig`と`lsof`でIPとportを確認する。
2. server/conductorの起動logからbind endpointを確認する。
3. conductor monitorを1周期以上待ち、`LIST`応答を確認する。
4. idle nodeがlocal server以外を含む場合は、`SUBMIT`せず停止する。
5. 単発jobのtask ID、job ID、callback、`DONE`を照合する。
6. 終了後に`lsof`でlistener消滅を確認する。

### Phase 1: 実装方針をまとめる — 完了

- 既存の `SYNCOPADE_NODE_PROFILE=lan100` と `SYNCOPADE_WIRED_PREFIX=192.168.100.` をserver/conductor/clientで共通使用する。
- serverとconductorは既存entrypointから別processとして起動し、排他・dispatch・状態遷移ロジックは変更しない。
- serverには `SYNCOPADE_MOUNT_ROOT_UNIX` でrepositoryの `test/` directoryを指定し、副作用のない `syncopadeBasicTestScript.test` を単発jobに使用する。
- conductorには `SYNCOPADE_CONDUCTOR_LOG` で実験専用一時logを指定する。
- 既存exampleはcallback addressに `getipaddr()` を使い、このPCでは `192.168.12.2` を選ぶため使用しない。
- `preferred_local_ip()` を使う既存client関数を短いJulia commandから呼び、callbackを `192.168.100.30` に固定する。
- `SUBMIT`前にconductorの `LIST` を取得し、idle endpoint集合が `{192.168.100.30:8030}` と一致しなければ停止する。
- 単発jobは `submit_conductor_task_and_wait` で投入し、task ID、job ID、callback payload、conductor `DONE` logを照合する。
- 起動前後のport確認とprocess終了はshell側で行い、repository sourceの実装は不要とする。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### 起動interface

- 共通環境変数:
  - `SYNCOPADE_NODE_PROFILE=lan100`
  - `SYNCOPADE_WIRED_PREFIX=192.168.100.`
- server固有入力:
  - `SYNCOPADE_MOUNT_ROOT_UNIX=<repository>/test`
  - entrypoint: `julia --project=. syncopadeServer.jl`
  - 期待bind: `192.168.100.30:8030`
- conductor固有入力:
  - `SYNCOPADE_CONDUCTOR_LOG=<temporary-directory>/conductor_events.csv`
  - entrypoint: `julia --project=. syncopadeConductor.jl`
  - 期待bind: `192.168.100.30:9030`

#### 事前検査interface

- `query_server_status("192.168.100.30", 8030)` の期待値は `STATUS|idle`。
- `parse_conductor_nodes(query_conductor_nodes("192.168.100.30"; conductor_port=9030))` の期待値は `[("192.168.100.30", 8030)]` の1件だけ。
- IP不一致、port使用中、status不一致、idle node集合不一致はすべて`SUBMIT`前の停止条件とする。

#### 単発job interface

- 呼出関数: `submit_conductor_task_and_wait`
- conductor endpoint: `192.168.100.30:9030`
- coordinator IP: `192.168.100.30`
- callback port: `9130`
- source/module/function: `syncopadeBasicTestScript:syncopadeBasicTestScript:test`
- args: `["[2,3,5]", "[7,11,13]"]`
- timeout: `30.0` seconds
- 期待callback: `ok == true`, `payload == "30030.0"`
- 戻り値の`task_id`と`job_id`をconductor event logへ照合する。

#### 副作用

- serverは`8030/tcp`、conductorは`9030/tcp`、callback receiverは一時的に`9130/tcp`をlistenする。
- conductorは既存`lan100`候補へ周期的な`STATUS` probeを行う。
- job dispatchは事前検査合格後のlocal server 1件にだけ許可する。
- serverは`test/syncopadeBasicTestScript.jl`をincludeし、関数cacheへ登録する。
- repository内の既存logは書き換えず、conductor event logだけを一時directoryへ新規作成する。
- callback listenerは関数終了時にcloseされ、server/conductorは検証後に明示終了する。

### Phase 3: 実装する — 完了（source変更なし）

- Phase 2で固定した入出力は、既存entrypoint、環境変数、公開client関数だけで構成できる。
- Step 1専用のsource実装やtest harness追加は不要と判定した。
- 排他制御、dispatch、server状態遷移、既存test/exampleは変更していない。
- 実行時に生成するのはrepository外の一時logだけとする。

### Phase 4: テストまたは検証を行う — 完了

- 実行revision: `8ec26972020072a77926137462df0d65f81f8547`
- server PID/endpoints: `92073`, `192.168.100.30:8030`
- conductor PID/endpoints: `92081`, `192.168.100.30:9030`
- `SUBMIT`前server status: `STATUS|idle`
- `SUBMIT`前idle nodes: `[("192.168.100.30", 8030)]`
- task ID: `2faac457-3ebd-4389-9ea5-ac5b4a51ba42`
- worker job ID: `d98f76e3-2285-4859-ab17-b919a447b510`
- callback: `ok=true`, `payload=30030.0`
- `TASK_DONE`: worker `192.168.100.30:8030`, status `OK`, callback `true`
- job終了後server status: `STATUS|idle`
- cleanup: `8030/tcp`, `9030/tcp`, `9130/tcp`にlistenerなし
- repositoryの既存`logs/conductor_events.csv`には、この検証による追記なし
- receipt: `/tmp/syncopade-step1.mLa0jk/receipt.md`
- conductor event log: `/tmp/syncopade-step1.mLa0jk/conductor_events.csv`

## Step 2: server単体のbusy受付再現 — 完了（現象再現）

### 目的

local server上でjob Aを実行中にjob Bを直接投入し、serverが`busy`中の2件目を拒否せず受理する現象を、conductorのdispatch競合から分離して確認する。

### 対象ファイル

- `syncopadeClient.jl`（既存client protocolを使用）
- `syncopadeServer.jl`（変更せず観測対象とする）
- `test/fixtures/server_busy_probe.jl`（新規fixture）
- `test/integration_server_busy_acceptance.jl`（新規manual integration harness）
- 実験専用一時directoryのserver logとreceipt

### 完了条件

- job Aが`OK|STARTED|jobId`を受信し、serverが`STATUS|busy`となる。
- `busy`確認後に投入したjob Bの受付応答を記録する。
- job Bも`OK|STARTED|jobId`で受理された場合、server側の受付排他違反を再現済みと判定する。
- 両jobのcallback、開始順序、終了時刻、wall timeを記録する。
- serverは1processだけ使用する。

### 検証方法

1. job Aへ十分な`sleep`時間を与えて投入する。
2. `STATUS|busy`を確認してからjob Bを投入する。
3. job Bの即時応答が受付、拒否、保留のどれかを記録する。
4. 両jobのjob IDとcallbackを照合する。
5. 両jobの実行時間が重なった場合は、wall timeとcallback時刻でも裏付ける。

### Phase 1: 実装方針をまとめる — 完了

- conductorを介さず、実際のserver 1processへ2件のjobを直接送る。
- job Aを投入し、protocolの`STATUS|busy`を観測してからjob Bを投入する。
- job Bの同期的な受付応答が`OK|STARTED|jobId`なら、`busy`中の受付違反を独立に確認できる。
- 専用fixtureはmodule globalのactive counterをlockで保護し、各jobの`active_at_entry`、`max_active`、`started_ns`、`finished_ns`をcallback payloadへ返す。
- job A/Bは同じsource/module/functionを指定し、serverの同じfunction cacheとmodule stateを共有させる。
- fixture内の`sleep`で実行区間を意図的に広げ、時刻区間の交差と`max_active >= 2`を別々に判定する。
- 専用harnessは2つのone-shot callback listenerを先に起動し、job IDとcallback job IDを照合する。
- server/clientのstdout・stderrは実験専用directoryへ全量保存し、receiptへcommand、PID、revision、時刻、判定値を残す。
- serverの排他・受付・状態遷移ロジックには変更を加えない。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### Fixture仕様

- file/module/function: `test/fixtures/server_busy_probe.jl:SyncopadeServerBusyProbe:busy_probe`
- signature: `busy_probe(label::String, sleep_seconds::String)::String`
- `sleep_seconds`は有限かつ正の`Float64`だけを受理する。
- module globalとしてactive job数と観測最大値を保持し、`ReentrantLock`で更新する。
- job開始時にactive数をincrementし、例外の有無にかかわらず`finally`でdecrementする。
- 戻り値は`label`, `active_at_entry`, `max_active`, `started_ns`, `finished_ns`を含むcomma区切りkey-value文字列とする。
- `started_ns`と`finished_ns`は同一server processの`time_ns()`で取得する。

#### Harness仕様

- file: `test/integration_server_busy_acceptance.jl`
- CLI入力:
  1. server IP（default `192.168.100.30`）
  2. server port（default `8030`）
  3. job A callback port（default `9131`）
  4. job B callback port（default `9132`）
  5. job sleep seconds（default `3.0`）
  6. callback timeout seconds（default `15.0`）
- callback bind IPは`preferred_local_ip()`から取得し、server IPと一致しなければ投入前に停止する。
- job A/B用のone-shot callback listenerを先に起動する。
- 初期`STATUS|idle`を確認後、job Aを投入する。
- `STATUS|busy`をtimeout内に確認してからjob Bを投入する。
- job Bの`syncopade_calc_request`がjob IDを返したことを受付evidenceとする。
- callback job ID、成功status、payloadを各requestと照合する。
- fixtureの2区間が交差し、かつ最大active数が2以上であることを実行重複evidenceとする。
- 両callback後にserverが`STATUS|idle`へ戻ることを確認する。

#### 副作用と停止条件

- serverは`8030/tcp`、callbackは`9131/tcp`と`9132/tcp`を一時listenする。
- serverはfixture moduleをincludeし、function cacheとmodule global stateを保持する。
- conductorは起動せず、conductor event logも生成しない。
- server/clientのstdout・stderrは別fileへ全量保存する。
- IP、port、初期status、busy status、callback、ID、payload、区間交差のいずれかが仕様外なら即時失敗とする。
- `test/runtests.jl`には追加せず、明示起動したserverを必要とするmanual integration testとして分離する。

### Phase 3: 実装する — 完了

- `test/fixtures/server_busy_probe.jl`を追加した。
- `test/integration_server_busy_acceptance.jl`を追加した。
- server本体、client protocol、排他・状態遷移ロジックには変更を加えていない。
- harnessは`PROGRAM_FILE` guardを持ち、includeだけではnetwork接続しない。
- fixture単独local checkで`active_at_entry=1`、`max_active=1`、`started_ns < finished_ns`を確認した。
- harnessのpayload parserでfixture出力を正常に復元できることを確認した。

### Phase 4: テストまたは検証を行う — 完了（再開後に現象再現）

#### 初回試行: job投入前に停止

- 実行revision: `8ec26972020072a77926137462df0d65f81f8547`
- server PID: `92616`
- `lsof`では `192.168.100.30:8030` のlistenを確認した。
- raw stdoutを通常fileへredirectしたため、process実行中はstartup行が未flushだった。
- live readiness確認の`rg`が失敗し、後続のprotocol `STATUS`確認前に停止した。
- callback listenerは起動しておらず、job A/Bは1件も投入していない。
- serverは`q`で正常終了し、exit codeは`0`だった。
- 終了後、`8030/tcp`, `9131/tcp`, `9132/tcp`にlistenerが残っていないことを確認した。
- process終了時にstdoutはflushされ、期待したbind行が保存された。stderrは空だった。
- receipt: `/tmp/syncopade-step2.tEwPj0/receipt.md`
- live readinessを`lsof`とprotocol `STATUS`で判定し、raw log本文はprocess終了後に検査する方法へ修正して再開した。

#### 再開試行: 現象再現

- 実行revision: `8ec26972020072a77926137462df0d65f81f8547`
- server PID/endpoint: `92792`, `192.168.100.30:8030`
- client exit code: `0`
- server exit code: `0`
- 初期status: `STATUS|idle`
- job B投入直前status: `STATUS|busy`
- job A ID: `19e7ad9b-daab-432c-81cc-1d040b09d709`
- job B ID: `a19094fa-9a69-46ed-aaf8-3f1f03097156`
- job Bは`busy`中に`OK|STARTED|jobId`で受理された。
- job A `active_at_entry=1`
- job B `active_at_entry=2`
- 観測最大active job数: `2`
- server process内の実行区間重複: `true`
- 区間重複時間: `3002350125 ns`（`3.002350125 s`）
- 両callback成功後status: `STATUS|idle`
- raw server/client stderrはともに空だった。
- cleanup後、`8030/tcp`, `9131/tcp`, `9132/tcp`にlistenerなし。
- repositoryの既存`logs/conductor_events.csv`には、この検証による追記なし。
- receipt: `/tmp/syncopade-step2-resume.D9dqpo/receipt.md`
- server stdout/stderr: `/tmp/syncopade-step2-resume.D9dqpo/server.stdout.log`, `/tmp/syncopade-step2-resume.D9dqpo/server.stderr.log`
- client stdout/stderr: `/tmp/syncopade-step2-resume.D9dqpo/client.stdout.log`, `/tmp/syncopade-step2-resume.D9dqpo/client.stderr.log`

## Step 3: conductor経由の重複dispatch再現 — Phase 4で停止（自然race未再現）

### 目的

単一のlocal serverだけがdispatch可能な状態で複数`SUBMIT`を短時間に並行投入し、conductor経由で同一server上のjob実行区間が重なるか確認する。

### 対象ファイル

- `syncopadeClient.jl`（既存conductor submit/callback protocolを使用）
- `syncopadeConductor.jl`（変更せず観測対象とする）
- `syncopadeServer.jl`（変更せず観測対象とする）
- `test/fixtures/server_busy_probe.jl`（Step 2で追加したfixtureを再利用）
- `test/integration_conductor_node_exclusivity.jl`（新規manual integration harness）
- 実験専用一時directoryのconductor/server logとreceipt

### 完了条件

- `SUBMIT`直前のidle node一覧が `192.168.100.30:8030` の1件だけである。
- 計画数、投入数、受付task ID数、callback数を記録する。
- conductor task ID、worker job ID、worker endpointを対応付ける。
- 同一worker endpointについて2件以上のjob実行時間区間が重なれば、conductor経由の重複実行を再現済みと判定する。
- 重複を観測できない場合は、試行数、投入timing、timeout、欠落callbackを含めて未再現と記録する。
- timing制御を追加したくなった場合は実装せず、Todo全体の見直しを先生へ提案する。

### 検証方法

1. conductor monitorと`LIST`でlocal serverだけがidleであることを再確認する。
2. 複数callback listenerを先に起動してから、複数`SUBMIT`を並行送信する。
3. conductor event logの`TASK_QUEUED`、`DISPATCH_START`、`DISPATCH_OK`、`TASK_DONE`を照合する。
4. `started_at`と`finished_at`から同一worker上の実行区間交差を判定する。
5. callback receiptとconductor event logの件数・IDを突合する。
6. 終了後にchild processとlistenerが残っていないことを確認する。

### Phase 1: 実装方針をまとめる — 完了

- productionのconductor/server/client、排他制御、dispatch、状態遷移ロジックは変更しない。
- Step 1と同じ`lan100`構成でconductor 1process、server 1processだけを起動する。
- `SUBMIT`直前にserver statusとconductor `LIST`を検査し、local server 1件だけがidleでなければ停止する。
- 元依頼の最終batchと同じ20 taskを計画数とする。
- 20個のcallback listenerをすべてbindしてから、20個の`SUBMIT` taskを共通gateで同時解放する。
- 各taskには固有labelとcallback portを割り当て、conductor task IDとcallback worker job IDを1対1対応させる。
- Step 2の`SyncopadeServerBusyProbe.busy_probe`を再利用し、server process内のactive数と実行区間をcallback payloadへ残す。
- conductor event logの`DISPATCH_OK`と`TASK_DONE`からtask ID、job ID、worker endpoint、開始・終了時刻を突合する。
- callback payloadの`max_active >= 2`かつ実行区間交差を、同一server上の重複実行evidenceとする。
- server/conductor/clientのstdout・stderr、conductor event CSV、receiptを実験専用directoryへ全量保存する。
- 自然なraceを1回観測し、重複未観測またはtimeoutなら未再現として停止する。timing制御は追加しない。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### Harness仕様

- file: `test/integration_conductor_node_exclusivity.jl`
- CLI入力:
  1. conductor IP（default `192.168.100.30`）
  2. conductor port（default `9030`）
  3. server IP（default `192.168.100.30`）
  4. server port（default `8030`）
  5. task数（default `20`）
  6. callback base port（default `9200`; 使用portは`base + 1:task数`）
  7. job sleep seconds（default `3.0`）
  8. callback/log timeout seconds（default `90.0`）
  9. conductor event CSV path（省略時は`SYNCOPADE_CONDUCTOR_LOG`）
- callback bind IPは`preferred_local_ip()`で取得し、conductor/server IPと一致しなければ停止する。
- 初期server statusは`STATUS|idle`、conductor idle node集合は`[("192.168.100.30", 8030)]`の1件だけを要求する。
- 全callback portをbindしてreceiver taskを起動した後、共通`Event`で全submit taskを同時解放する。
- 各taskのfixture labelは`run-0001`形式とし、callback portと1対1対応させる。
- 各callbackについてchecksum、status、label、job ID、payloadを検証する。
- callback payloadから`active_at_entry`, `max_active`, `started_ns`, `finished_ns`を復元する。
- conductor event CSVはread-onlyで解析し、各task IDについて`DISPATCH_OK`と`TASK_DONE`を1件ずつ要求する。
- conductor logのjob IDをcallback job IDへ照合し、worker endpointが全件`192.168.100.30:8030`であることを確認する。
- fixtureのnanosecond区間とconductor `TASK_DONE`のmillisecond区間について、重複pair数をそれぞれ算出する。

#### 合格・未再現・失敗条件

- 計画数、受付task ID数、callback数、成功callback数がすべて20で一致する。
- task IDとjob IDがそれぞれ20件すべてuniqueである。
- `max_active >= 2`、fixture区間重複pair数1以上、conductor区間重複pair数1以上なら現象再現と判定する。
- 全taskが終端しても重複条件を満たさない場合は未再現として非zero終了する。
- timeout、callback ERROR、checksum不正、ID不一致、worker endpoint不一致、log欠落は検証失敗として非zero終了する。

#### 副作用

- clientはcallback base portに続く20 portを一時listenする。
- conductorは既存`lan100` node候補へ周期的な`STATUS` probeを行う。
- serverはStep 2のfixture moduleをincludeし、active counterをprocess内で共有する。
- harnessはconductor event CSVを変更せず、読取りと照合だけを行う。
- server/conductor/clientのraw stdout・stderrはPhase 4の実行側で別fileへ保存する。
- harnessは`PROGRAM_FILE` guardを持ち、includeだけではnetwork接続しない。

### Phase 3: 実装する — 完了（2回停止後に再開）

- 再現用ハーネス `test/integration_conductor_node_exclusivity.jl` を追加した。
- production source（server / conductor / client）の改訂は行っていない。
- ネットワーク実験前のローカル読込チェックで停止した。
  - 実行:
    `julia --project=. -e 'include("test/integration_conductor_node_exclusivity.jl"); println("HARNESS_INCLUDE_OK")'`
  - 結果:
    `ERROR: LoadError: UndefVarError: TCPServer not defined in Main`
  - 発生箇所:
    `receive_callback(listener::TCPServer)` の型注釈。
  - 原因:
    `TCPServer` は `Sockets` 名前空間の型であり、現在の記述では `Main.TCPServer` として解決できない。
- エラー発生前に停止したため、Step 3ではserver / conductorを起動しておらず、job投入も0件、実験ログも未生成。
- 1回目の再開で、関数引数とlistener配列の型参照を `Sockets.TCPServer` に限定した。
- 同じローカル読込チェックを再実行し、型解決箇所を越えた後、次の構文エラーで再停止した。
  - 結果:
    `ParseError: test/integration_conductor_node_exclusivity.jl:279:13 unexpected ')'`
  - 発生箇所:
    `push!(submit_tasks, @async begin ... end,)` の閉じ括弧。
  - 原因候補:
    関数引数内に置いた括弧なしの `@async begin ... end` と末尾commaの組合せを、Julia parserが有効な `push!` 呼出しとして解釈できていない。
- 再開時の最小修正案:
  `@async begin ... end` の戻り値を一度local変数に受け、その変数を `push!(submit_tasks, ...)` へ渡す形に分離して、Phase 3のローカル読込チェックを再実行する。
- 今回もnetwork処理前に停止したため、Step 3ではserver / conductorを起動しておらず、job投入も0件、実験ログも未生成。
- 2回目の再開で、`@async begin ... end` の戻り値を `submit_task` に受けてから `push!` する形へ分離した。
- harness全体を静的に再確認した後、同じローカル読込チェックを実行した。
  - 結果: `HARNESS_INCLUDE_OK`
  - exit code: `0`
  - include時のnetwork接続: なし（`PROGRAM_FILE` guardによる）。
- Phase 3の変更対象は再現用harnessだけであり、production source（server / conductor / client）は未改訂。

### Phase 4: テストまたは検証を行う — 停止（自然race未再現）

- 実行revision: `8ec26972020072a77926137462df0d65f81f8547`
- 使用topology:
  - server: `192.168.100.30:8030`, PID `95649`
  - conductor: `192.168.100.30:9030`, PID `95650`
  - callback ports: `9201:9220`
- 起動前に`192.168.100.30`の保持、`8030`, `9030`, `9201:9220`の空きを確認した。
- listener起動後のfail-closed事前検査で、idle nodeが `[('192.168.100.30', 8030)]` の1件だけであることを確認した。
- 自然race条件:
  - 計画task数: `20`
  - 共通gateから20個の`SUBMIT` taskを解放
  - fixture sleep: `3.0 s`
  - timeout: `90.0 s`
- conductor event照合結果:
  - `TASK_QUEUED`: `20`
  - `DISPATCH_START`: `20`
  - `DISPATCH_OK`: `20`
  - `TASK_DONE`: `20`
  - unique conductor task ID: `20`
  - unique worker job ID: `20`
  - worker endpoint: 全件 `192.168.100.30:8030`
  - status: 全件 `OK`
  - callback_ok: 全件 `true`
  - conductor実行区間の重複pair数: `0`
  - `NO_IDLE_REQUEUE`: `77`
  - first started: `2026-08-28T20:02:34.534`
  - last finished: `2026-08-28T20:03:46.553`
- harnessはcallback 20件のchecksum、status、label、task/job ID対応を通過後、`max_active=1`で次の判定に失敗した。
  - exit code: `1`
  - error: `overlap not reproduced: max_active=1`
- この1回の自然raceでは、conductorがdispatch後にworkerをidle集合から外し、busy中は次taskをrequeueしたため、20 taskは直列実行された。
- 今回の結論は「未再現」であり、依頼書の断続的な現象が存在しないことは示さない。
- Phase 1の方針どおりtiming hookや追加試行は行わず、B進行の停止規則に従って停止した。
- cleanup:
  - serverは`q`で終了しexit code `0`
  - conductorは`SIGTERM`で終了しexit code `143`
  - `8030`, `9030`, `9201:9220`にlistenerなし
- repositoryの既存`logs/conductor_events.csv`にStep 3のtimestamp/task ID/job ID追記なし。
- receipt: `/tmp/syncopade-step3.lRayD6/receipt.md`
- conductor event log: `/tmp/syncopade-step3.lRayD6/conductor_events.csv`
- server stdout/stderr: `/tmp/syncopade-step3.lRayD6/server.stdout.log`, `/tmp/syncopade-step3.lRayD6/server.stderr.log`
- conductor stdout/stderr: `/tmp/syncopade-step3.lRayD6/conductor.stdout.log`, `/tmp/syncopade-step3.lRayD6/conductor.stderr.log`
- harness stdout/stderr: `/tmp/syncopade-step3.lRayD6/harness.stdout.log`, `/tmp/syncopade-step3.lRayD6/harness.stderr.log`
- post-run診断時、line countのglobがruntime FIFOも対象にして`wc`が待機したため、診断shell PID `95947`とchild PID `95948`だけを終了した。実験process終了後の事象で、artifactへの影響はない。
