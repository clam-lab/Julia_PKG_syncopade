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

## Step 3: busy中の2件目をwire protocolで明示拒否する

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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 4: 正常終了後に次jobを再受付できることを確認する

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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 5: job異常終了後にも受付を解放できることを確認する

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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手
