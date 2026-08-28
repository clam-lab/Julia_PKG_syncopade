# Syncopade server busy時の投入拒否 Todo

## 目的

単一serverを同時に1件だけ実行する資源として扱う現在のmodelを維持し、
`busy`中に到着した2件目の計算要求をserverが受理するバグを修正する。

今回の修正対象はserver側のjob受付境界だけとする。
conductor側のnode状態競合、重複dispatch、retry方針は変更しない。

## 正本と既知evidence

- 問題定義: `REQUEST_syncopade_node_execution_exclusivity.md`
- 再現記録: `history/TODO_syncopade_single_pc_exclusivity_reproduction.md`
- 修正前baseline tag: `v0.1.0`
- 修正作業開始時HEAD: `a5382fbf7c684bfda8843a40258c74accb63cf44`
- server単体再現結果:
  - job A実行中に`STATUS|busy`を確認した。
  - job Bも`OK|STARTED|jobId`で受理された。
  - `max_active=2`、実行区間重複を観測した。

## 守るべき不変条件

server capacityを1とすると、受理済みactive job数は常に

\[
n_{\mathrm{active}}(t) \in \{0,1\}
\]

でなければならない。

job受付の線形化点では、`idle`を観測した1要求だけが`busy`へ遷移できる。
その後に到着した要求は、先行jobが終端するまで受理されてはならない。

## 今回やらないこと

- `syncopadeConductor.jl`のnode選択、状態更新、monitor、retryの変更
- conductorがserverのBUSY拒否を専用分岐で扱う設計
- server側queueやcapacity 2以上の導入
- client public APIの全面的な例外型整理
- function cache、callback、DONE protocolの無関係な整理
- `logs/conductor_events.csv`の既存dirty差分への変更
- 既知の`test/runtests.jl`によるconductor entrypoint自動起動問題の修正

BUSY拒否のwire表現は明示的に識別可能なものとし、正確な文字列と
client側の既存挙動との境界は、該当StepのPhase 2で固定する。

## 共通停止条件

- 一度に進めるのは1 Step、その中でも1 Phaseずつとする。
- Todo作成はStep 1 Phase 1とは扱わない。
- 指示されたStep以外へ進まない。
- source変更は各StepのPhase 3だけで行う。
- error、test failure、想定外のlistener、既存dirty fileへの追記があれば停止する。
- 新しいStepが必要なら勝手に追加せず、Todo全体の見直しを先生へ提案する。

---

## Step 1: server entrypointを試験可能に分離する — 完了

### 目的

`syncopadeServer.jl`をunit testからincludeしただけではserver processが起動しない状態にする。
後続Stepで受付状態遷移だけをnetworkなしで検証できる試験入口を作る。

### 対象ファイル

- `syncopadeServer.jl`
- 必要な場合のみ、server entrypoint確認用の小さなstandalone test file

### 完了条件

- `include("syncopadeServer.jl")`だけではlistenerが起動しない。
- include後にserver内部関数を呼出せる。
- `julia --project=. syncopadeServer.jl`による通常起動は従来どおり動く。
- serverのbind IP、port、受付protocolは変更しない。

### 検証方法

1. 別Julia processからfileをincludeし、processが即時正常終了することを確認する。
2. include前後でserver portにlistenerが増えないことを確認する。
3. `lan100` profileで通常entrypointを起動し、`STATUS|idle`を確認する。
4. 起動したserverを終了し、listenerが残らないことを確認する。

### Phase 1: 実装方針をまとめる — 完了

- include時の副作用はfile末尾の無条件`main()`呼出しだけから生じることを確認した。
- `main()`関数本体、`syncopade_server()`、bind target解決、受付protocolは変更しない。
- file末尾の呼出しだけを`PROGRAM_FILE` guardで囲む最小差分とする。
- guardは既存manual integration harnessと同じ形式を使い、直接scriptとして実行された場合だけ`main()`を呼ぶ。
- Step 1専用test fileは追加せず、別Julia processからのincludeと既存entrypointの実起動で検証する。
- `syncopadeConductor.jl`の無条件`main()`は既知の別問題だが、今回のscope外なので変更しない。
- 既存dirtyの`logs/conductor_events.csv`は変更しない。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### Entrypoint guard仕様

- 判定式: `abspath(PROGRAM_FILE) == @__FILE__`
- 直接実行入力: `julia --project=. syncopadeServer.jl`
- 直接実行時出力: 従来どおり`main()`を1回呼び、serverを起動する。
- include入力: `include("syncopadeServer.jl")`
- include時出力: 定数と関数を定義して戻り、`main()`は自動実行しない。
- include後に`main()`を明示呼出しした場合は、従来と同じserver起動処理を実行する。
- guard自体は引数、戻り値、例外、network I/O、file I/Oを持たない。

#### 副作用境界

- 直接実行時だけserver listenerを作成する。
- include時はbind、node probe、log追記、child process生成を行わない。
- `server_state`、function cacheなどのglobal定義は従来どおり評価される。
- bind IP/portは既存のprofile解決結果を使用し、Step 1では変更しない。

#### Phase 4検証interface

- include check:
  `julia --project=. -e 'include("syncopadeServer.jl"); println("SERVER_INCLUDE_OK")'`
- 通常起動環境:
  `SYNCOPADE_NODE_PROFILE=lan100`, `SYNCOPADE_WIRED_PREFIX=192.168.100.`
- 期待endpoint: `192.168.100.30:8030`
- protocol check: `query_server_status("192.168.100.30", 8030) == "STATUS|idle"`
- cleanup: serverへ`q`を入力し、exit code `0`と`8030/tcp` listener消滅を要求する。

### Phase 3: 実装する — 完了

- `syncopadeServer.jl`末尾の無条件`main()`呼出しを、Phase 2で固定した`PROGRAM_FILE` guardで囲んだ。
- `main()`本体、server起動、bind target、受付protocol、状態管理には変更を加えていない。
- 新規test fileやproduction helperは追加していない。
- 対象fileの`git diff --check`はerrorなし。
- production変更は2行追加、1行置換相当のentrypoint差分だけである。

### Phase 4: テストまたは検証を行う — 完了

#### Include検証

- 実行前`8030/tcp`: listenerなし
- command: `julia --project=. -e 'include("syncopadeServer.jl"); println("SERVER_INCLUDE_OK")'`
- exit code: `0`
- output: `SERVER_INCLUDE_OK`
- 実行後`8030/tcp`: listenerなし

#### 通常entrypoint検証

- environment:
  - `SYNCOPADE_NODE_PROFILE=lan100`
  - `SYNCOPADE_WIRED_PREFIX=192.168.100.`
- command: `julia --project=. syncopadeServer.jl`
- server PID: `98557`
- bind: `192.168.100.30:8030`
- protocol response: `STATUS|idle`
- status query exit code: `0`
- server終了入力: `q`
- server exit code: `0`
- cleanup後`8030/tcp`: listenerなし
- server/status stderr: 空
- raw logs: `/tmp/syncopade-step1-entrypoint.kxudZH/`

#### Step 1結論

- include時の自動起動だけを除去できた。
- 通常entrypointのbind、status応答、終了動作は維持された。
- Step 1の完了条件をすべて満たした。

---

## Step 2: server受付状態遷移をatomicにする — 完了

### 目的

socket、job実行、callbackから独立した最小の受付状態遷移を定義する。
`idle`からの最初の要求だけが予約に成功し、後続要求が失敗することを単体で保証する。

### 対象ファイル

- `syncopadeServer.jl`
- `test/unit_server_admission_state.jl`（新規standalone unit test候補）

### 完了条件

- server状態の読取り、`idle -> busy`予約、`busy -> idle`解放が同じ同期境界を使用する。
- 初期`idle`に対する最初の予約だけが成功する。
- `busy`中の予約は状態を変更せず失敗する。
- 解放後は再度1件だけ予約できる。
- 4個の競合する予約試行に対し、成功数が厳密に1件となる。
- このStepではsocket handlerの受付応答をまだ変更しない。

### 検証方法

1. networkを起動せず、初期状態、最初の予約、2回目の予約、解放、再予約を順に検査する。
2. 共通gateから4個の予約試行を解放し、成功数と最終状態を検査する。
3. test終了時に状態を`idle`へ解放できることを確認する。
4. server portにlistenerが存在しないことを確認する。

### Phase 1: 実装方針をまとめる — 完了

- `server_state[]`の直接accessは、初期化を除くとSTATUS読取り、job受付後のbusy書込み、job終端時のidle書込みの3箇所だけと確認した。
- `server_state_lock::ReentrantLock`を追加し、状態読取り、予約、解放を小さなhelperへ集約する。
- 予約helperはlock内で`idle`だけを`busy`へ変更し、成功可否を`Bool`で返すcheck-and-setとする。
- 解放helperは、Step 2時点では既存の重複実行挙動を壊さないようidempotentに`idle`へ戻す。
- STATUS応答、受付後のbusy遷移、job終端時のidle遷移は、すべてhelper経由に置換して直接accessをなくす。
- Step 2ではwire応答を変更しない。受付handlerは従来どおり先に`OK|STARTED`を返し、その後で予約helperを呼ぶ。
- 予約helperが`false`を返してもStep 2では拒否分岐へ入れず、既存の受理挙動を維持する。戻り値を受付判断へ接続するのはStep 3とする。
- standalone unit testを追加し、networkなしで逐次状態遷移と4個の競合予約を検査する。
- `syncopadeClient.jl`、`syncopadeConductor.jl`、wire protocolは変更しない。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### Global synchronization

- `server_state_lock::ReentrantLock`
- 保護対象: `server_state[]`の初期化後の全読取り・全書込み
- lock保持中にnetwork I/O、callback、function実行、sleepを行わない。

#### `get_server_state()::Symbol`

- 入力: なし
- 出力: lock取得時点の`:idle`または`:busy`
- 副作用: なし
- 例外: lock取得自体の失敗以外は想定しない。

#### `try_reserve_server!()::Bool`

- 入力: なし
- 初期状態が`:idle`の場合、同じlock区間で`:busy`へ変更して`true`を返す。
- 初期状態が`:busy`の場合、状態を変更せず`false`を返す。
- checkとstate更新の間でlockを解放しない。
- job ID生成、socket応答、function実行、callbackは行わない。

#### `release_server!()::Nothing`

- 入力: なし
- lock内で状態を`:idle`へ変更する。
- `:idle`で呼ばれた場合もerrorにせず`:idle`を維持する。
- network I/O、callback、DONE通知は行わない。

#### 既存handlerへのStep 2接続

- STATUS応答は`get_server_state()`を使用する。
- 従来の受付後`server_state[] = :busy`を`try_reserve_server!()`呼出しへ置換する。
- Step 2では予約戻り値を拒否判断に使わず、wire応答とjob実行数を変えない。
- job終端時の`server_state[] = :idle`を`release_server!()`へ置換する。

#### Standalone unit test

- file: `test/unit_server_admission_state.jl`
- 実行: `julia --project=. --threads=4 test/unit_server_admission_state.jl`
- 逐次検査:
  初期idle、最初の予約成功、2回目失敗、busy維持、解放、再予約成功、最終解放。
- 競合検査:
  idle状態から4個の`Threads.@spawn`で予約し、`true`が1件、`false`が3件、最終状態がbusyであることを要求する。
- `try/finally`でtest終了時に`release_server!()`を呼び、成功・失敗時ともidleへ戻す。
- testはserver fileをincludeするが、Step 1 guardによりlistenerを起動しない。

### Phase 3: 実装する — 完了

- `syncopadeServer.jl`へ`server_state_lock`と3 helperを追加した。
  - `get_server_state()::Symbol`
  - `try_reserve_server!()::Bool`
  - `release_server!()::Nothing`
- STATUS、受付後busy遷移、job終端idle遷移をhelper経由へ置換した。
- 初期化を除く`server_state[]`の直接accessは3 helper内部だけになった。
- Step 2のscopeどおり、`OK|STARTED`応答順序とjob受理数は変更していない。
- `test/unit_server_admission_state.jl`を追加した。
- unit testは逐次遷移、再予約、4個の競合予約、最終idle cleanupを検査する。
- 対象fileの`git diff --check`はerrorなし。

### Phase 4: テストまたは検証を行う — 完了

- command: `julia --project=. --threads=4 test/unit_server_admission_state.jl`
- Julia thread数: `4`
- test result: `13 / 13 pass`
- 検証済み項目:
  - 初期状態`idle`
  - 最初の予約だけ成功
  - `busy`中の2回目予約は失敗し、状態を維持
  - 解放後の再予約成功
  - 4個の競合予約に対して`true=1`, `false=3`
  - 競合予約後の状態`busy`
  - `finally` cleanup後の状態`idle`
- test前後の`8030/tcp`: listenerなし
- test exit code: `0`
- Step 2では意図どおりwire応答を変更しておらず、BUSY拒否の実接続検証はStep 3へ残す。
- Step 2の完了条件をすべて満たした。

---

## Step 3: busy中の2件目をwire protocolで明示拒否する — 完了

### 目的

Step 2の受付状態遷移を実際の計算要求handlerへ接続し、
先行jobがactiveな間に到着した2件目へ成功応答やjob IDを発行しない。

### 対象ファイル

- `syncopadeServer.jl`
- `syncopadeClient.jl`（既存応答解釈の確認対象。必要性をPhase 1で判定する）
- `test/fixtures/server_busy_probe.jl`
- `test/integration_server_busy_acceptance.jl`（修正前evidenceとして読取り対象）
- `test/integration_server_busy_rejection.jl`（新規manual integration test候補）

### 完了条件

- job Aの受付時、成功応答を返す前にserverが予約済み状態となる。
- job A実行中のjob Bへ、BUSYと識別できる拒否応答を返す。
- job Bに`OK|STARTED`やjob IDを返さない。
- job Bのfunctionを実行しない。
- job BのRESULT callbackとDONE通知を生成しない。
- job Aだけが実行され、fixtureの`max_active`が`1`となる。
- rejection後もjob A実行中の`STATUS`は`busy`を維持する。

### 検証方法

1. conductorを起動せず、`lan100`のlocal server 1本だけを起動する。
2. callback listenerを準備してjob Aを投入する。
3. `STATUS|busy`を確認後、job Bを投入してraw受付応答を記録する。
4. job Bがjob ID、callback、function実行を持たないことを確認する。
5. job Aのpayloadから`active_at_entry=1`, `max_active=1`を確認する。
6. raw server/client stdout・stderrと実験receiptをrepository外へ保存する。
7. cleanup後にserver/callback listenerが残らないことを確認する。

### Phase 1: 実装方針をまとめる — 完了

- `convMSG2JOB`で要求形式を検証した後、job ID生成と成功応答より前に`try_reserve_server!()`を呼ぶ。
- 予約成功時だけjob IDを生成し、従来の`OK|STARTED|jobId`を返してjob taskを開始する。
- 予約失敗時は明示的なBUSY拒否応答を返し、そのconnection handlerを終了する。
- 拒否経路ではjob ID生成、function call、RESULT callback、DONE通知を行わない。
- socket応答またはjob task生成が失敗した場合に予約が残留しないよう、connection handler側で予約ownershipを追跡し、job taskへhandoffする前の例外では解放する。
- job taskへhandoffした後の正常・異常終端解放は既存`finally`とStep 4/5の検証範囲に残す。
- `syncopadeClient.syncopade_calc_request`はBUSY応答を既存どおりunexpected response errorとして扱えるため、Step 3では変更しない。
- BUSY wire応答そのものを検証するため、job Bだけはintegration harnessからraw requestを送る。
- 修正前再現用`test/integration_server_busy_acceptance.jl`は履歴evidenceとして変更せず、新しいrejection harnessを追加する。
- 新harnessはA/Bそれぞれのcallback listenerを自前で保持し、A callback受信までB callbackが到着しないことを確認後、全listenerを明示closeする。
- Step 3ではA終了後のjob C再受付を行わず、Step 4の独立検証として残す。
- conductorは起動せず、`syncopadeConductor.jl`と既存logは変更しない。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### Server受付protocol

- 正常受付応答: 既存どおり`OK|STARTED|<job-id>`
- capacity不足応答: `ERROR|BUSY`
- いずれも既存start-ackと同じくchecksumを付けない1行応答とする。
- `ERROR|BUSY`はjob IDを含まない。
- BUSY拒否後はsocketをcloseし、connection handlerをreturnする。
- `STATUS`、`CACHE_CLEAR`、checksum errorの既存分岐は変更しない。

#### 予約ownership

- well-formed jobをparseした後、`try_reserve_server!()`成功時だけconnection handlerが予約を所有する。
- job task生成前のsocket/job setup errorではconnection handlerが`release_server!()`を呼ぶ。
- job taskを正常に生成した時点でownershipをtaskへhandoffする。
- BUSY拒否時は予約を取得していないため解放処理を行わない。

#### Integration harness

- file: `test/integration_server_busy_rejection.jl`
- CLI入力:
  1. server IP（default `192.168.100.30`）
  2. server port（default `8030`）
  3. job A callback port（default `9141`）
  4. job B callback port（default `9142`）
  5. job sleep seconds（default `3.0`）
  6. timeout seconds（default `15.0`）
- callback IPは`preferred_local_ip()`から取得し、server IPと一致しなければjob投入前に停止する。
- A/B両方のcallback listenerをjob投入前にbindする。
- job Aは既存`syncopade_calc_request`で投入し、job IDを得る。
- `STATUS|busy`確認後、job Bは既存request encodingとchecksumを使うraw helperで投入する。
- job Bのraw応答は厳密に`ERROR|BUSY`と一致させる。
- A callbackはchecksum、job ID、status、payloadを検証する。
- B callback listenerは拒否後も`job sleep + 1 s`以上開き、callbackが1件も到着しないことを確認する。
- A payloadは`label=A`, `active_at_entry=1`, `max_active=1`, `started_ns < finished_ns`を要求する。
- A callback後の最終statusはcleanup確認として`STATUS|idle`を要求するが、job Cの再投入はStep 4へ残す。
- harnessは`PROGRAM_FILE` guardを持ち、includeだけではnetwork接続しない。

#### Phase 4 process構成

- server mount root: repositoryの`test/fixtures`
- server environment:
  `SYNCOPADE_NODE_PROFILE=lan100`, `SYNCOPADE_WIRED_PREFIX=192.168.100.`
- conductorは起動しない。
- server/client stdout・stderrとreceiptはrepository外の一時directoryへ保存する。
- `8030`, `9141`, `9142`は起動前に空きを確認し、終了後にlistener消滅を確認する。

### Phase 3: 実装する — 完了

- `syncopadeServer.jl`のjob parse直後にatomic予約分岐を接続した。
- 予約失敗時は`ERROR|BUSY`を返してconnection handlerを終了する。
- job ID生成と`OK|STARTED`応答は予約成功後だけ行う。
- connection handlerへ`reservation_owned`を追加し、job task生成前の例外では予約を解放する。
- job task生成後は既存taskの`finally`へ予約ownershipをhandoffする。
- `syncopadeClient.jl`と`syncopadeConductor.jl`は変更していない。
- 修正前evidenceの`test/integration_server_busy_acceptance.jl`は変更していない。
- `test/integration_server_busy_rejection.jl`を追加した。
- harnessはA/B listener、raw B request、BUSY応答、B callback不在、Aのactive数、最終statusを検証する。
- harnessのinclude check: `REJECTION_HARNESS_INCLUDE_OK`, exit code `0`。
- 対象fileの`git diff --check`はerrorなし。

### Phase 4: テストまたは検証を行う — 完了

#### Regression check

- command: `julia --project=. --threads=4 test/unit_server_admission_state.jl`
- result: `13 / 13 pass`
- exit code: `0`

#### Integration environment

- pre-Step-3 HEAD: `4226be21f3ead88d4cb92670c7c80b23c5a550ab`
- server PID/endpoint: `560`, `192.168.100.30:8030`
- callback IP: `192.168.100.30`
- callback ports: A=`9141`, B=`9142`
- conductor: 未起動
- 起動前にlocal IP保持と`8030`, `9141`, `9142`の空きを確認した。

#### Integration result

- harness result: `STEP3_RESULT=PASS_BUSY_REJECTED`
- harness exit code: `0`
- server exit code: `0`
- initial status: `STATUS|idle`
- job A ID: `452a0b47-2995-4f70-a374-1579b970df73`
- job B投入直前status: `STATUS|busy`
- job B raw response: `ERROR|BUSY`
- job B job ID: 発行なし
- job B callback: 観測なし
- job A `active_at_entry=1`
- job A `max_active=1`
- job A interval: `716362158220125..716365159218500 ns`
- final status: `STATUS|idle`
- server/harness stderr: ともに空
- cleanup後`8030`, `9141`, `9142`: listenerなし
- repositoryの`logs/conductor_events.csv`: 既存4行dirtyのまま、Step 3由来の追記なし
- receipt: `/tmp/syncopade-step3-rejection.bFLHjE/receipt.md`
- raw logs: `/tmp/syncopade-step3-rejection.bFLHjE/`

#### Step 3結論

- busy中の2件目は成功応答とjob IDを得ず、wire上で明示拒否された。
- 拒否jobのcallbackとfunction実行evidenceはなく、受理jobのactive数は1を維持した。
- 正常終了後のjob C再受付は未検証であり、Step 4へ残した。
- Step 3の完了条件をすべて満たした。

---

## Step 4: 正常終了後に次jobを再受付できることを確認する — 完了

### 目的

busy拒否を追加した結果、正常終了後もserverが永久にbusyへ残る退行を防ぐ。
job lifecycleの正常終端と受付解放が対応することを確認する。

### 対象ファイル

- `syncopadeServer.jl`
- Step 3で確定したbusy rejection integration test
- `test/fixtures/server_busy_probe.jl`

### 完了条件

- job A実行中のjob Bは拒否される。
- job AのRESULT callback完了後、serverが`STATUS|idle`となる。
- idle復帰後のjob Cは`OK|STARTED|jobId`で受理される。
- job CのRESULT callbackが成功する。
- job Aからjob Cまでの全観測で`max_active=1`を維持する。
- job Bの拒否がjob Cの受付を妨げない。

### 検証方法

1. Step 3と同じsingle-server構成でA受理、B拒否を確認する。
2. Aのcallback後に`STATUS|idle`を待つ。
3. 同じserverへjob Cを投入し、受付job IDとcallback job IDを照合する。
4. A/Cの実行区間が重ならず、fixtureの最大active数が1であることを確認する。
5. 最終statusとlistener cleanupを確認する。

### Phase 1: 実装方針をまとめる — 完了

- Step 3で確定した`test/integration_server_busy_rejection.jl`を拡張し、A受理・B拒否の全assertionを維持したままjob Cを追加する。
- production sourceは変更せず、Step 3実装済みの`release_server!()`正常終端経路をblack-boxで検証する。
- job C callback listenerはA/Bと同様にjob投入前にbindする。
- A callbackと`STATUS|idle`を確認した後だけjob Cを投入する。
- job Cは既存`syncopade_calc_request`で投入し、`OK|STARTED|jobId`の成功経路を使用する。
- C callbackのjob ID、status、label、active数、実行区間を検証する。
- AとCのfixture区間が重ならないこと、A/C双方の`max_active=1`を要求する。
- B callback不在を確定した後はB listenerを明示closeし、job C検証中に不要なlistenerを残さない。
- 既存CLI 1〜6の意味は変えず、job C callback portだけを末尾のoptional引数として追加する。
- Step 4では正常終了経路だけを扱い、ERROR callback後の再受付はStep 5へ残す。
- `syncopadeServer.jl`、client、conductor、fixtureは変更しない見込みとする。実装が必要になった場合はPhase 3へ進まず停止してTodo見直しを提案する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### Harness CLI追加

- 既存引数1〜6はStep 3仕様を維持する。
- 7番目にjob C callback portを追加し、defaultを`9143`とする。
- A/B/Cのcallback portはすべて異なる値を要求する。
- 旧Step 3 commandが7番目を省略しても、default C portで同じ拡張testを実行する。

#### Job C lifecycle

- A callback成功後、B callback不在の観測windowを完了する。
- B listenerをcancel/closeし、receiver taskが終了したことを確認する。
- `wait_for_server_status(..., "STATUS|idle", timeout)`でA終端後のidleを確認する。
- label `C`、Aと同じsleep seconds、callback port Cで`SyncopadeClient`を構築する。
- `syncopade_calc_request(client_c)`の戻り値をjob C IDとする。
- C callbackのjob IDが受付IDと一致し、statusがOKであることを要求する。
- C payloadは`label=C`, `active_at_entry=1`, `max_active=1`, `started_ns < finished_ns`を要求する。
- `probe_a.finished_ns <= probe_c.started_ns`を要求し、A/C区間が重ならないことを確認する。
- C callback後の最終statusは`STATUS|idle`を要求する。

#### Outputと合格条件

- Step 3 assertion成功を`STEP3_RESULT=PASS_BUSY_REJECTED`で維持する。
- Step 4合格を`STEP4_RESULT=PASS_NORMAL_RECOVERY`で出力する。
- A/C job ID、A終端後status、C payload、区間重複判定、最終statusをstdoutへ残す。
- A受理、B拒否、B callbackなし、A後idle、C受理、C callback OK、A/C非重複、最終idleがすべて成立した場合だけexit code `0`とする。

#### Phase 4 process構成

- server: `192.168.100.30:8030`
- callback ports: A=`9141`, B=`9142`, C=`9143`
- fixture sleep: `3.0 s`
- timeout: `15.0 s`
- 起動前後に`8030`, `9141`, `9142`, `9143`のlistenerを検査する。
- server/harness raw stdout・stderrとreceiptはrepository外の一時directoryへ保存する。

### Phase 3: 実装する — 完了

- `test/integration_server_busy_rejection.jl`へjob C recovery検証を追加した。
- 既存CLI 1〜6を維持し、7番目にC callback portを追加した。
- A/B/C callback portの相互重複checkを追加した。
- C listenerはA/Bと同様に投入前にbindする。
- B callback不在の観測後にB listenerを明示closeし、receiver task終了を確認する。
- A終端後の`STATUS|idle`確認後だけjob Cを投入する。
- C callback ID/status/payload、A/C区間非重複、最終idleのassertionを追加した。
- `STEP4_RESULT=PASS_NORMAL_RECOVERY`とC evidenceをstdoutへ追加した。
- production source、client、conductor、fixtureは変更していない。
- harness include check: `RECOVERY_HARNESS_INCLUDE_OK`, exit code `0`。
- 対象fileの`git diff --check`はerrorなし。

### Phase 4: テストまたは検証を行う — 完了

#### Regression check

- command: `julia --project=. --threads=4 test/unit_server_admission_state.jl`
- result: `13 / 13 pass`
- exit code: `0`

#### Integration environment

- pre-Step-4 HEAD: `cb632970066361b2a60fbdc9e4d1c38cb9d1b856`
- server PID/endpoint: `1436`, `192.168.100.30:8030`
- callback IP: `192.168.100.30`
- callback ports: A=`9141`, B=`9142`, C=`9143`
- conductor: 未起動
- 起動前にlocal IP保持と`8030`, `9141`, `9142`, `9143`の空きを確認した。

#### Integration result

- Step 3 regression: `STEP3_RESULT=PASS_BUSY_REJECTED`
- Step 4 result: `STEP4_RESULT=PASS_NORMAL_RECOVERY`
- harness exit code: `0`
- server exit code: `0`
- initial status: `STATUS|idle`
- job A ID: `aa3d246f-287f-446d-b842-af2faf3cede5`
- job B投入直前status: `STATUS|busy`
- job B response: `ERROR|BUSY`
- job B callback: 観測なし
- job A終端後status: `STATUS|idle`
- job C ID: `b1c7b3db-96ee-447e-a71d-0f9780774240`
- job A `active_at_entry=1`, `max_active=1`
- job C `active_at_entry=1`, `max_active=1`
- job A interval: `716730861819125..716733863978750 ns`
- job C interval: `716734876737208..716737879184333 ns`
- A/C interval overlap: `false`
- final status: `STATUS|idle`
- server/harness stderr: ともに空
- cleanup後`8030`, `9141`, `9142`, `9143`: listenerなし
- repositoryの`logs/conductor_events.csv`: 既存4行dirtyのまま、Step 4由来の追記なし
- receipt: `/tmp/syncopade-step4-recovery.fRkIRn/receipt.md`
- raw logs: `/tmp/syncopade-step4-recovery.fRkIRn/`

#### Step 4結論

- 正常job Aの終端後にserverはidleへ復帰した。
- BUSY拒否されたjob Bは、その後のjob C受付を妨げなかった。
- job Cは新しいjob IDを得て正常callbackまで完了した。
- A/Cは直列実行され、active job数は常に1だった。
- job ERROR後のidle復帰と再受付は未検証であり、Step 5へ残した。
- Step 4の完了条件をすべて満たした。

---

## Step 5: job異常終了後にも受付を解放できることを確認する — 完了

### 目的

job実行が例外終了した場合にもserverが`busy`へ残留せず、
次の正常jobを受理できることを正常終了経路から分離して確認する。

### 対象ファイル

- `syncopadeServer.jl`
- Step 3/4で確定したintegration test
- 必要な場合のみ、明示的に例外を送出する最小fixture

### 完了条件

- 受理されたjob DがRESULT ERRORで終端する。
- job D実行中の別要求はBUSY拒否される。
- job D終端後、serverが`STATUS|idle`となる。
- その後の正常job Eが受理され、RESULT OKで終端する。
- error経路でもactive job数が1を超えない。
- 最終statusが`idle`で、listenerが残らない。

### 検証方法

1. 例外を発生させるjob Dを投入し、実行中のBUSY拒否を確認する。
2. DのERROR callbackとjob IDを照合する。
3. D終端後の`STATUS|idle`を確認する。
4. 正常job Eを投入し、受付、callback、最終statusを確認する。
5. server/client stderrとcallback欠落がないことを確認する。
6. Step 1/2のstandalone testとStep 3/4/5のmanual integration testを再実行する。

### Phase 1: 実装方針をまとめる — 完了

- Step 5専用のintegration testを追加し、Step 3/4の通信helperと正常job fixtureを再利用する。
- 例外終了job Dを一定時間`busy`に保つため、既存fixture moduleへ明示的に例外を送出する最小関数だけを追加する。
- D実行中に正常job Rを投入し、raw応答`ERROR|BUSY`とcallback不在を確認する。
- Dの`RESULT ERROR` callback受信後に`STATUS|idle`を確認し、その後の正常job Eの受付と`RESULT OK`を確認する。
- concurrency evidenceはfixture moduleの既存counterを共有し、DとEの各entryでactive job数が1、観測最大値が1であることを確認する。
- 現在のserverはjob taskの`finally`で`release_server!()`を呼び、callback失敗とDONE通知失敗も関数内で捕捉するため、Phase 1時点ではproduction source変更を予定しない。
- Step 5でproduction source変更の必要が判明した場合は、その場で停止してTodo全体の見直しを先生へ提案する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### 例外fixture

- file: `test/fixtures/server_busy_probe.jl`
- function: `failing_probe(label::String, sleep_seconds::String)::String`
- 入力検証は既存`busy_probe`と同じく、`label`の`,`/`=`を禁止し、sleepは有限かつ正値を要求する。
- module共有counterをlock下でincrementし、`active_at_entry`、`max_active`、`started_ns`を記録する。
- 指定時間sleep後、`intentional failure: `に続く既存probe形式のevidenceを含む`ErrorException`を必ず送出する。
- `finally`でactive countをdecrementし、負値にならないことを検査する。
- 戻り値型はserver呼出しinterfaceに合わせて`String`とするが、正常returnはしない。

#### Error recovery integration harness

- file: `test/integration_server_error_recovery.jl`
- Step 3/4 harnessをincludeし、通信、callback、status、正常payload解析helperを再利用する。
- entrypoint名は`error_recovery_main`とし、`PROGRAM_FILE` guardによりincludeだけではnetwork接続しない。
- CLI入力:
  1. server IP（default `192.168.100.30`）
  2. server port（default `8030`）
  3. job D callback port（default `9151`）
  4. rejected job R callback port（default `9152`）
  5. job E callback port（default `9153`）
  6. job sleep seconds（default `3.0`）
  7. timeout seconds（default `15.0`）
- callback IPは`preferred_local_ip()`で取得し、server IPと一致しなければ投入前に停止する。
- D/R/Eのlistenerを投入前にbindし、3 portの重複を禁止する。
- Dは`failing_probe`、R/Eは既存`busy_probe`を呼ぶ。
- D受付後に`STATUS|busy`を確認し、Rをraw投入して応答が厳密に`ERROR|BUSY`であることを要求する。
- D callbackは受付時job IDとの一致、`RESULT ERROR`、error type `RUNTIME_ERROR`、構造化されたD evidenceを要求する。
- R listenerは拒否後`job sleep + 1 s`以上保持し、callbackがないことを確認して明示closeする。
- D終端後に`STATUS|idle`を確認してからEを投入し、job ID一致、`RESULT OK`、正常payloadを要求する。
- D/Eのevidenceはともに`label`一致、`active_at_entry=1`、`max_active=1`、正の実行区間を要求する。
- 最後に`STATUS|idle`と全callback taskの終了を確認し、全listenerを`finally`でもcloseする。

#### Phase 4 process構成

- server mount root: repositoryの`test/fixtures`
- server environment: `SYNCOPADE_NODE_PROFILE=lan100`, `SYNCOPADE_WIRED_PREFIX=192.168.100.`
- conductorは起動しない。
- 1本のserver processに対してStep 3/4 harnessを先に再実行し、その後Step 5 harnessを実行する。
- server/client stdout・stderrとreceiptはrepository外の一時directoryへ保存する。
- `8030`, `9141`–`9143`, `9151`–`9153`は起動前に空きを確認し、終了後にlistener消滅を確認する。

### Phase 3: 実装する — 完了

- `test/fixtures/server_busy_probe.jl`へ`failing_probe`を追加した。
- `failing_probe`は既存module counterを共有し、sleep後にconcurrency evidenceを含む意図的な例外を送出し、`finally`でactive countを戻す。
- `test/integration_server_error_recovery.jl`を追加した。
- harnessはDのERROR、実行中RのBUSY拒否とcallback不在、D後のidle、Eの正常受付、D/Eの排他evidence、最終idleを検証する。
- 再開時にfailure evidenceを`String`へ明示変換し、既存`parse_probe_payload(::String)`との型境界を揃えた。
- `syncopadeServer.jl`、client、conductor、Step 3/4 harnessは変更していない。

### Phase 4: テストまたは検証を行う — 完了

#### 完了したprecheck

- server include check: `STEP1_SERVER_INCLUDE_OK`
- admission state unit test: `13 / 13 pass`
- local lan100 IP: `192.168.100.30`
- 起動前port check: `8030`, `9141`–`9143`, `9151`–`9153`は空き。
- serverは`192.168.100.30:8030`へ正常bindした。

#### 停止理由

- Step 3/4回帰harness起動時にlan100用環境変数を渡さなかったため、`preferred_local_ip()`が`192.168.12.2`を選択した。
- harnessは投入前guardで`callback IP 192.168.12.2 does not match server IP 192.168.100.30`を検出し、jobを1件も投入せず停止した。
- これはStep 5 sourceのtest failureではなく、harness processの起動条件ミスである。
- B進行のerror停止規則に従い、環境変数を補正した再実行には進んでいない。
- serverは正常終了させ、終了後port checkで`8030`, `9141`–`9143`, `9151`–`9153`がすべて解放済みであることを確認した。
- repositoryの`logs/conductor_events.csv`にはStep 5由来の追記を行っていない。
- raw logs: `/tmp/syncopade-step5-error-recovery.SA697K/`

#### 再開条件

- Step 3/4およびStep 5 harness processにも`SYNCOPADE_NODE_PROFILE=lan100`, `SYNCOPADE_WIRED_PREFIX=192.168.100.`を渡し、Phase 4を先頭から再実行する。

#### 再開試行1

- server、Step 3/4 harness、Step 5 harnessの全processへlan100環境変数を渡した。
- server include check: `STEP1_SERVER_INCLUDE_OK`
- admission state unit test: `13 / 13 pass`
- Step 3 regression: `STEP3_RESULT=PASS_BUSY_REJECTED`
- Step 4 regression: `STEP4_RESULT=PASS_NORMAL_RECOVERY`
- Step 3/4 server/harness stderr: 空
- Step 5ではjob DのERROR callback受信後、evidence解析で停止した。
- error: `MethodError: no method matching parse_probe_payload(::SubString{String})`
- 原因: `parse_failure_payload`がprefix除去後の`SubString{String}`を、`String`限定の既存helperへそのまま渡している。
- 最小修正案: `parse_probe_payload(String(evidence))`として型を明示的に揃える。
- B進行のtest failure停止規則に従い、修正と再実行には進んでいない。
- serverはexit code `0`で終了した。
- cleanup後の`8030`, `9141`–`9143`, `9151`–`9153`: listenerなし。
- raw logs: `/tmp/syncopade-step5-error-recovery-resume.5oGnzK/`

#### 再開試行1後の再開条件

- Phase 3へ戻り、`parse_failure_payload`の型変換を上記最小差分で修正する。
- harness include checkと差分check後、Phase 4をprecheckから再実行する。

#### 再開試行2・最終検証

- failure parser check: `STEP5_FAILURE_PARSER_OK`
- server include check: `STEP1_SERVER_INCLUDE_OK`
- admission state unit test: `13 / 13 pass`
- 起動前port check: `8030`, `9141`–`9143`, `9151`–`9153`は空き。
- server endpoint: `192.168.100.30:8030`
- callback IP: `192.168.100.30`
- conductor: 未起動
- Step 3 regression: `STEP3_RESULT=PASS_BUSY_REJECTED`
- Step 4 regression: `STEP4_RESULT=PASS_NORMAL_RECOVERY`
- job A ID: `5d9dec58-71ef-4d9a-af27-1c09960306f9`
- job B response: `ERROR|BUSY`、callback観測なし。
- job C ID: `76091539-18e1-4250-8d2d-6ab3f784bcb1`
- A/Cの`active_at_entry=1`, `max_active=1`、interval overlap=`false`。
- Step 5 result: `STEP5_RESULT=PASS_ERROR_RECOVERY`
- job D ID: `1bfbbdd8-d358-42a9-8fc8-5ca773b2926f`
- job D callback: `RUNTIME_ERROR|intentional failure`、受付job IDと一致。
- job R response: `ERROR|BUSY`、callback観測なし。
- job D終端後status: `STATUS|idle`
- job E ID: `0d5f71d3-82b9-41b1-bd39-253404af7efb`
- D/Eの`active_at_entry=1`, `max_active=1`、interval overlap=`false`。
- 最終status: `STATUS|idle`
- server、Step 3/4 harness、Step 5 harness stderr: すべて空。
- server exit code: `0`
- cleanup後の`8030`, `9141`–`9143`, `9151`–`9153`: listenerなし。
- repositoryの`logs/conductor_events.csv`: 既存4行dirtyのまま、Step 5由来の追記なし。
- raw logs: `/tmp/syncopade-step5-error-recovery-final.padWZs/`
- receipt: `/tmp/syncopade-step5-error-recovery-final.padWZs/receipt.md`

#### Step 5結論

- 異常終了job Dの実行中は別job Rを受理せず、job IDもcallbackも発生させなかった。
- DのERROR callback後にserverはidleへ復帰し、正常job Eを新規受理できた。
- error経路と回復後の正常経路はいずれもactive job数1を維持した。
- Step 5の完了条件をすべて満たした。
