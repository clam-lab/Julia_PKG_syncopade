# Syncopade BUSY配送・無通知破棄 修正前再現試験 Todo

## 目的

`v0.1.3`で報告された次の連鎖を、production codeを修正する前に、このPCだけで再現して記録する。

1. 遅れて反映された`STATUS|idle`が、後から設定された`busy`を上書きする。
2. workerの`ERROR|BUSY`が配送故障として扱われ、再試行回数を消費してタスクが破棄される。
3. conductorが受付済みタスクを破棄しても、親へtask ID付きの終了通知が届かない。

試験は、応答順を制御できる偽workerによる決定的な再現を正本とする。最後に`lan100`上でconductor 1本、server 1本を実際に起動し、偽worker試験の前提と実TCP経路を確認する。

このTodoは**修正前の再現と証拠固定だけ**を対象とする。原因修正、通信仕様変更、修正後の回帰試験は別Todoとする。

## 正本と調査基準

- 改訂依頼書: `REQUEST_syncopade_busy_dispatch_and_terminal_notification.md`
- 調査対象: commit `8dfcc135b9c87c13950757cc344fb398a98fe708`、tag `v0.1.3`
- 正本ログ: `/Volumes/syncopade_nfs/conductor_events.csv`
- 正本ログSHA-256: `24a832f322b35197a18fef7a986fc8c8b07c494be670142abb17375d9a0fde2f`
- 対象task ID: `5799dcc7-078f-431d-abe9-f323c5724c82`
- 実ログ上の配送開始から破棄まで: `0.291 s`

再現試験では、修正前の不具合を観測できた場合を`PASS_REPRODUCED`と記録する。これは正しい動作を意味しない。修正後には期待値を反転させ、別Todoで回帰試験へ作り替える。

## 今回の判定対象

### 必須の不具合再現

- 古い`idle`観測が新しい`busy`状態を上書きできる。
- `ERROR|BUSY`が一般例外になり、nodeが`down`へ変更される。
- `BUSY`拒否が通常の配送再試行回数を消費する。
- retry `0, 1, 2, 3`の4回後に同じtask IDが`TASK_DROPPED`となる。
- drop後にqueueからタスクが消える。
- drop後も親の結果受信口へtask ID付き終了通知が来ない。

### 壊れていないことを確認する正常系

- serverは同時に1件だけ受理する。
- 使用中の2件目には`ERROR|BUSY`を返す。
- `BUSY`時にworker job IDを発行しない。
- 先行タスク終了後は次のタスクを受理できる。

### 修正後Todoへ送る項目

次は今回の実ログで発生が確定していないため、この修正前Todoの必須再現には含めない。ただし、同じ状態管理を直す際の回帰対象として記録する。

- 古いまたは重複した`DONE`が、新しい割当てを`idle`へ戻さないこと。
- worker受付応答のtimeout後に、同一task IDを二重実行しないこと。
- 終端通知が重複しても、親が二重完了として数えないこと。

## 共通制約

- production codeは変更しない。
- 修正、暫定sleep、retry回数変更、状態遷移変更を混ぜない。
- 修正前の誤動作を期待する試験は`test/runtests.jl`へ登録しない。
- test helperと再現scriptは、修正後に期待値を反転できる構造にする。
- `logs/conductor_events.csv`の先生の既存4行差分を変更・stage・復元しない。
- conductor event log、stdout、stderr、receiptはrepository外の一時directoryへ置く。
- `192.168.12.*`の実運用conductor/serverへ接続・配送しない。
- 実network確認には`lan100` profileだけを使用する。
- `lan100`のidle node集合が`192.168.100.30:8030`の1件でなければ、タスク投入前に停止する。
- 起動したprocessとlistenerは、成功・失敗にかかわらず終了処理する。
- error、予期しないendpoint、既存logの変化、cleanup失敗があればそのPhaseで停止する。
- Step追加・分割・順序変更が必要なら作業を進めず、Todo全体の見直しを先生へ提案する。
- 進行方式は強化C進行とする。
- 通常C進行どおり、各Step内でPhase 1→2→3→4を一つずつ順に実行し、検証成功後にそのStepの対象差分だけをcommit/pushして次Stepへ自動で進む。
- コーディング上の文字間違い、構文ミス、Markdownの改行・空白など、Todoの目的・前提・仕様・完了条件を変えない局所的な灯子のミスは、自律的に修正して同じPhaseの検証をやり直す。
- Todoの切り直し、Step追加・分割・順序変更、前提変更、仕様変更、完了条件変更が必要な齟齬では停止し、先生へ報告する。

---

## Step 1: 応答順を制御できる偽workerを用意して単体確認する — 完了

### 目的

実機の偶然の通信順序に依存せず、`STATUS|idle`の遅延、`ERROR|BUSY`、正常受理を試験側から明示的に発生させられる最小のTCP相手を用意する。

### 対象ファイル

- `test/fixtures/conductor_controlled_worker.jl`（新規候補）
- `test/unit_controlled_worker_fixture.jl`（新規候補）
- このTodo

### 完了条件

- loopbackの空きportだけへbindする。
- test側の合図が来るまで`STATUS`応答を保留できる。
- 指定回数だけ`ERROR|BUSY`を返せる。
- 指定時には`OK|STARTED|<job_id>`を返せる。
- 受信した要求数、応答種別、応答時刻を取得できる。
- helper単体確認後にlistenerとtaskが残らない。
- repository内の既存logを変更しない。

### 検証方法

1. 偽workerをloopbackの自動選択portで起動する。
2. `STATUS`要求が届いたことを確認し、応答保留中にclient側が待っていることを確認する。
3. 合図後に`STATUS|idle`を返し、clientが受信することを確認する。
4. job要求へ`ERROR|BUSY`と正常受理を指定順に返す。
5. 要求履歴、listener終了、port解放、既存log不変を確認する。

### Phase 1: 実装方針をまとめる — 完了

- 偽workerは`module`内へ閉じ込め、既存のclient/conductor globalと名前衝突させない。
- `127.0.0.1`のport `0`へlistenし、OSが割り当てた空きportだけを使う。
- 接続ごとにchecksum付きrequestを検証し、`STATUS`とjob requestを分類する。
- request受信をtest側へ通知してから、状態応答用またはjob応答用の`Channel`で待つ。これにより、sleep時間ではなく明示的な合図で応答順を固定する。
- 応答は既存workerと同じraw形式で、`STATUS|idle`、`ERROR|BUSY`、`OK|STARTED|<job_id>`をtest側から指定する。
- request/responseの種別、payload、時刻をlock付き履歴へ保存する。
- cleanupはlistener、応答待ちchannel、接続処理taskを閉じ、bounded waitで残留を検出する。
- helper単体testで遅延STATUS、BUSY拒否、正常受理を順番に確認する。
- 修正前の不具合を期待する再現testではないため、helper単体testは通常の正方向assertだけにする。ただし、このStepでは`test/runtests.jl`へまだ登録しない。
- production sourceと既存testは変更しない。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### `start_controlled_worker() -> ControlledWorker`

- `127.0.0.1:0`でlistenerを作り、実際に割り当てられたIPとportを保持する。
- accept loopを非同期に開始する。
- STATUS応答channel、job応答channel、request通知channel、履歴、接続task一覧を所有する。
- 起動だけでは外部network、repository file、conductor状態へ触れない。

#### `wait_for_request(worker, expected_kind; timeout=2.0)`

- `expected_kind`は`:status`または`:job`。
- request通知channelがreadyになるまでbounded waitする。
- 戻り値は`request_id`、`kind`、checksum除去後payloadを表す`value`、記録時刻`recorded_ns`を持つNamedTupleとする。
- 受信したkindが期待値と異なる場合はerrorにする。
- timeout時に次のrequestを奪う待機taskを残さない。

#### `respond_status!(worker, response)` / `respond_job!(worker, response)`

- 対応するbounded channelへ、次の要求に返すraw 1行応答を追加する。
- Step 1で許可する応答は`STATUS|idle`、`STATUS|busy`、`ERROR|BUSY`、`OK|STARTED|<job_id>`。
- checksumは付けない。現行serverの即時応答形式をそのまま再現する。

#### `worker_history(worker)`

- lock内で履歴のcopyを返す。
- request受信とresponse送信を別eventとして持ち、sequence、kind、payload/response、時刻を照合できるようにする。

#### `stop_controlled_worker!(worker; timeout=2.0)`

- 停止flagを立て、listenerと応答channelを閉じる。
- accept taskと全接続taskが期限内に終了することを要求する。
- cleanup後に同じportへ再bindできることを単体test側で確認する。

#### Helper単体test

- 実行: `julia --project=. test/unit_controlled_worker_fixture.jl`
- STATUS要求受信後、応答許可前にclient taskが未完了であることを確認する。
- `STATUS|idle`許可後にclientが同じ応答を受信することを確認する。
- 1件目のjob requestへ`ERROR|BUSY`を返し、一般例外に応答本文が含まれることを確認する。
- 2件目のjob requestへ`OK|STARTED|controlled-job-1`を返し、同じjob IDを取得する。
- request履歴が`:status, :job, :job`、response履歴も対応する3件であることを確認する。
- `try/finally`でcleanupし、test終了時のlistener残留を許さない。

### Phase 3: 実装する — 完了

- `ConductorControlledWorker` moduleを新規追加した。
- loopback自動port、checksum検証、STATUS/job分類、応答channel、要求通知channel、lock付き履歴を実装した。
- listener、応答待ち、accept task、接続taskを終了するbounded cleanupを実装した。
- helper単体testを追加し、遅延STATUS、BUSY、正常受理、履歴対応、port再bindを検査するようにした。
- production source、既存test、`test/runtests.jl`は変更していない。

### Phase 4: テストまたは検証を行う — 完了

#### 初回検証と強化C補正

- 初回実行はhelper内のXOR代入演算子が`⊻=`でなく別記号になっていたため、request checksum不一致で停止した。
- production、server、conductorのerrorではなく、灯子による演算子1文字の入力ミスだった。
- Todoの目的・仕様・完了条件を変えない局所修正として`⊻=`へ直し、同じPhase 4を最初から再実行した。

#### 最終検証

- helper単体testを2回連続実行し、いずれも`15 / 15 pass`。
- result: `STEP1_RESULT=PASS_CONTROLLED_WORKER_FIXTURE`。
- 遅延STATUSは応答許可前にclient taskが未完了、許可後に`STATUS|idle`を受信した。
- BUSY要求は応答許可前にclient taskが未完了、許可後に例外本文`ERROR|BUSY`を取得した。
- 正常受理は`controlled-job-1`を返した。
- request/responseは`:status, :job, :job`、request ID `1, 2, 3`で対応した。
- cleanup後に同じportへ再bindでき、Julia listener/processは残らなかった。
- `git diff --check`と新規2 fileのwhitespace checkはerrorなし。
- repository log SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`のまま。

### Step 1結論

状態問い合わせとjob受付の応答時点を、実時間sleepに依存せずtest側の合図で固定できる。修正前の状態巻き戻りとBUSY処理を別々に検証する準備が成立した。

---

## Step 2: 古いidle観測によるbusy状態の巻き戻りを決定的に再現する — 完了

### 目的

`STATUS`問い合わせ開始時点と状態反映時点の間に配送状態を進め、古い`idle`応答が新しい`busy`を上書きする現行動作を、固定した順序で1回ずつ再現する。

### 対象ファイル

- `test/fixtures/conductor_controlled_worker.jl`
- `test/reproduction_conductor_stale_idle.jl`（新規候補）
- `syncopadeConductor.jl`（読取り・呼出しのみ）
- このTodo

### 完了条件

- 初期node状態を`idle`にする。
- 偽workerが`STATUS`要求を受け、`idle`応答を保留していることを確認する。
- 保留中にconductor状態を`busy`へ進める。
- 保留していた`idle`を返した後、現行コードが`busy -> idle`へ巻き戻す。
- 状態変更順、要求受信順、時刻を一時logへ記録する。
- ランダムな大量投入やsleepの偶然に依存せず再実行できる。

### 検証方法

1. `refresh_states_until_idle!`を非同期に開始する。
2. 偽workerの受信通知で、状態確認が開始済みであることを確定する。
3. `set_node_state!(node, NODE_BUSY)`を実行する。
4. 偽workerへ`STATUS|idle`の返信を許可する。
5. 最終状態が`NODE_IDLE`となり、一時logが`idle -> busy -> idle`を含むことを確認する。
6. 同じ試験を再実行し、同じ順序で再現する。

### Phase 1: 実装方針をまとめる — 完了

- testは独立Julia processで実行し、include前に`SYNCOPADE_CONDUCTOR_LOG`をrepository外artifactへ向ける。
- productionのconductor/server mainやmonitor loopは起動せず、`refresh_states_until_idle!`、`set_node_state!`、`get_node_state`だけを呼ぶ。
- 初期状態を`NODE_IDLE`へ設定した後、1 nodeだけの`refresh_states_until_idle!`を非同期に開始する。
- 偽workerのrequest通知をgateとして使い、STATUS request受信後かつresponse前に`NODE_BUSY`へ変更する。
- `NODE_BUSY`を確認してから、偽workerへ`STATUS|idle`の返信を許可する。
- refresh完了後の`NODE_IDLE`を修正前の巻き戻り成立条件とする。
- worker履歴のrequest時刻、busy設定時刻、response時刻がこの順であることをnanosecond値で検査する。
- conductor log writerを明示停止してから、一時CSVの`down -> idle -> busy -> idle`を確認する。
- `try/finally`で偽worker、log writer、node stateをcleanupする。
- 同じtestを2回実行し、どちらも固定順序で`PASS_REPRODUCED_STALE_IDLE`となることを要求する。
- production source、既存test、`test/runtests.jl`は変更しない。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### 再現test entrypoint

- file: `test/reproduction_conductor_stale_idle.jl`
- command: `SYNCOPADE_TEST_ARTIFACT_DIR=<repository外path> julia --project=. test/reproduction_conductor_stale_idle.jl`
- conductor log: `<artifact>/conductor_events.csv`
- network: `127.0.0.1`の自動割当てportだけを使用する。
- expected marker: `STEP2_RESULT=PASS_REPRODUCED_STALE_IDLE`。

#### 状態と同期順

1. `node_states`を空にし、偽nodeを`NODE_IDLE`へ設定する。
2. `refresh_states_until_idle!([node]; timeout=2.0)`を非同期に開始する。
3. `wait_for_request(worker, :status)`が返るまで待つ。
4. `set_node_state!(node, NODE_BUSY)`を呼び、読取りでも`NODE_BUSY`を確認する。
5. busy確認時刻を記録後、`respond_status!(worker, "STATUS|idle")`を呼ぶ。
6. refreshをbounded waitし、戻り値`true`と最終`NODE_IDLE`を要求する。

#### 時刻とlogの判定

- `request.recorded_ns < busy_confirmed_ns < response.recorded_ns`を要求する。
- worker request/responseは各1件で、request payloadは`STATUS`、responseは`STATUS|idle`とする。
- 一時conductor logのnode状態遷移は、順に`down -> idle`、`idle -> busy`、`busy -> idle`を各1件含む。
- 最後の`busy -> idle`を修正前不具合の再現証拠とする。

#### Cleanupと副作用

- `finally`でconductor log writer、偽worker、node stateを終了・初期化する。
- 一時artifact以外のfileを生成・変更しない。
- repository log SHA-1とGit差分を実行前後で一致させる。
- test timeoutや順序不一致では`PASS_REPRODUCED`を出さない。

### Phase 3: 実装する — 完了

- `test/reproduction_conductor_stale_idle.jl`を追加した。
- conductor mainやmonitorを起動せず、1 nodeの`refresh_states_until_idle!`だけを偽workerへ接続する構造にした。
- STATUS request受信後に`NODE_BUSY`を設定し、busy確認後に保留した`STATUS|idle`を返す明示同期を実装した。
- request、busy確認、responseのnanosecond順序と最終`NODE_IDLE`を検査する。
- 一時conductor CSVの`down -> idle -> busy -> idle`順序を検査する。
- `try/finally`でlog writer、偽worker、node stateをcleanupする。
- production source、既存test、`test/runtests.jl`は変更していない。

### Phase 4: テストまたは検証を行う — 完了

- 再現testを2回連続実行し、どちらも`19 / 19 pass`。
- result: `STEP2_RESULT=PASS_REPRODUCED_STALE_IDLE`。
- 1回目の状態遷移: `down -> idle -> busy -> idle`。
- 2回目の状態遷移: `down -> idle -> busy -> idle`。
- 両実行でSTATUS request受信後、response前の`NODE_BUSY`を確認した。
- 両実行で遅延`STATUS|idle`反映後の最終状態は`NODE_IDLE`となった。
- 1回目artifact: `/tmp/syncopade-stale-idle-step2.RRtqsL/`。
- 1回目CSV SHA-1: `770e48c0dbe4ce492a0154bf8636ae05d4cd6a88`。
- 2回目artifact: `/tmp/syncopade-stale-idle-step2-repeat.m3iuET/`。
- 2回目CSV SHA-1: `41c54ba52c83cac85d5fe1d774214da910f4a08b`。
- cleanup後、偽worker listenerとJulia processは残らなかった。
- `git diff --check`と新規testのwhitespace checkはerrorなし。
- repository log SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`のまま。

### Step 2結論

現行conductorは、STATUS問い合わせ後にnode状態が`busy`へ進んでも、その問い合わせの古い`idle`結果を無条件に適用する。状態辞書の個別lockだけでは観測の新旧を保証できないことを、固定順序で2回再現した。

---

## Step 3: BUSYの故障扱い・再試行消費・破棄を分離して再現する — 完了

### 目的

状態巻き戻りそのものとは分けて、workerの正常な`ERROR|BUSY`拒否がconductorで一般配送失敗となり、同一task IDの再試行回数を消費して破棄されることを確認する。

### 対象ファイル

- `test/fixtures/conductor_controlled_worker.jl`
- `test/reproduction_conductor_busy_drop.jl`（新規候補）
- `syncopadeClient.jl`（読取り・呼出しのみ）
- `syncopadeConductor.jl`（読取り・呼出しのみ）
- このTodo

### 完了条件

- 偽workerは各job要求へ`ERROR|BUSY`を返し、job IDを発行しない。
- `syncopade_calc_request`が`BUSY`を専用結果でなく例外として返す。
- `dispatch_to_worker`が`false`を返し、nodeを`down`へ変更する。
- 各配送cycle前に試験側で`idle`観測を再現し、同じtask IDをretry `0, 1, 2, 3`で4回配送する。
- 4回目の拒否後、queue lengthが0となり`TASK_DROPPED/max_retry_exceeded`が1回記録される。
- workerの受付回数は4回、実行回数とjob ID発行数は0回である。

### 検証方法

1. retry `0`の`ConductorTask`をqueueへ1件入れる。
2. nodeを`idle`として配送cycleを1回実行する。
3. `BUSY`、`down`、retry増加、同一task IDを確認する。
4. 同じ条件をretry `1, 2, 3`まで1cycleずつ繰り返す。
5. 最終queue、偽worker要求履歴、一時conductor logを照合する。
6. 初回配送からdropまでの実測時間を記録するが、0.291秒との完全一致は要求しない。

### Phase 1: 実装方針をまとめる — 完了

- Step 2の状態巻き戻りとは分離し、1回の配送cycleにつき偽workerの`ERROR|BUSY`を1回だけ返す。
- retry `0`の固定task IDをqueueへ1件だけ入れる。
- 各cycle直前に試験側でnodeを`NODE_IDLE`へ設定し、現行conductorが配送対象として選べる状態を明示的に作る。
- `run_dispatch_cycle!([node]; max_retry=3)`を4cycle実行する。
- 各cycle後にnodeが`NODE_DOWN`となることを確認する。
- 1〜3cycle後はqueue内に同じtask IDが1件だけ残り、retryが`1, 2, 3`へ増えることを確認する。
- 4cycle後はqueue length 0となることを確認する。
- worker履歴からjob request 4件、`ERROR|BUSY` response 4件、`OK|STARTED` 0件を確認する。
- 一時conductor logから`DISPATCH_START` 4件、`DISPATCH_FAILED` 4件、`TASK_REQUEUED` 3件、`TASK_DROPPED` 1件を確認する。
- 初回配送開始からdropまでの時間を記録するが、実ログの0.291秒との一致は要求しない。
- testは独立processで実行し、repository外log、bounded cleanup、既存log不変を維持する。
- production source、既存test、`test/runtests.jl`は変更しない。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### 再現test entrypoint

- file: `test/reproduction_conductor_busy_drop.jl`
- command: `SYNCOPADE_TEST_ARTIFACT_DIR=<repository外path> julia --project=. test/reproduction_conductor_busy_drop.jl`
- conductor log: `<artifact>/conductor_events.csv`
- expected marker: `STEP3_RESULT=PASS_REPRODUCED_BUSY_DROP`。
- elapsed output: `STEP3_DISPATCH_TO_DROP_SECONDS=<seconds>`。

#### 固定taskとnode

- task ID: `controlled-busy-drop-task`。
- initial retry: `0`。
- callback: `127.0.0.1:1`。偽workerは受付しないため接続しない。
- source/module/function: `controlled_source:ControlledModule:controlled_function`。
- node: Step 1のloopback偽worker 1件だけ。
- max retry: production defaultと同じ`3`。

#### 1cycleの判定

1. 次のjob responseとして`ERROR|BUSY`を偽workerへ登録する。
2. nodeを`NODE_IDLE`へ設定する。
3. `run_dispatch_cycle!`を1回呼ぶ。
4. nodeが`NODE_DOWN`となることを確認する。
5. cycle 1〜3ではqueueが同じtask IDをretry `1, 2, 3`で1件だけ保持する。
6. cycle 4ではqueue lengthが0となる。

#### Logとworker履歴

- task IDに対応する`DISPATCH_START`と`DISPATCH_FAILED`は各4件。
- `DISPATCH_FAILED`例外本文は4件とも`ERROR|BUSY`を含む。
- `TASK_REQUEUED`はretry `1, 2, 3`の3件。
- `TASK_DROPPED`はretry `3`、reason `max_retry_exceeded`の1件。
- worker request/responseは各4件ですべて`:job`、responseはすべて`ERROR|BUSY`。
- `OK|STARTED`応答とworker job IDは0件。

#### Cleanupと副作用

- `finally`でconductor log writer、偽worker、task queue、node stateを終了・初期化する。
- test timeout、件数不一致、task ID変化、listener残留ではPASS markerを出さない。
- repository log SHA-1と、Step 3対象外のGit差分を実行前後で維持する。

### Phase 3: 実装する — 完了

- `test/reproduction_conductor_busy_drop.jl`を追加した。
- retry `0`の固定taskを1件だけqueueへ入れ、各cycle前のnode `idle`と偽worker `ERROR|BUSY`を明示した。
- 4cycleそれぞれでnode `down`、1〜3cycleの同一task ID/retry、4cycle後のqueue消滅を検査する。
- worker要求・応答各4件、BUSY 4件、正常受理/job ID 0件を検査する。
- 一時CSVの配送開始・失敗・再queue・drop件数、retry `0〜3`、`max_retry_exceeded`を検査する。
- 初回cycle開始からdropまでのelapsed secondsを出力する。
- `try/finally`でlog writer、偽worker、task queue、node stateをcleanupする。
- production source、既存test、`test/runtests.jl`は変更していない。

### Phase 4: テストまたは検証を行う — 完了

- 再現testを2回連続実行し、どちらも`39 / 39 pass`。
- result: `STEP3_RESULT=PASS_REPRODUCED_BUSY_DROP`。
- 両実行で同じtask IDをretry `0, 1, 2, 3`の順に配送した。
- 各配送は偽workerの`ERROR|BUSY`で拒否され、conductor上のnodeは`down`となった。
- retry `1, 2, 3`ではqueueに同じtask IDが1件だけ残り、4回目の拒否後はqueue length 0となった。
- worker job request/responseは各4件、responseは全件`ERROR|BUSY`、正常受理/job ID発行は0件。
- 一時CSVは`DISPATCH_START=4`、`DISPATCH_FAILED=4`、`TASK_REQUEUED=3`、`TASK_DROPPED=1`。
- 4件の例外本文はすべて`Unexpected response from server: ERROR|BUSY`を含んだ。
- 1回目の配送開始からdropまで: `1.402634083 s`。
- 2回目の配送開始からdropまで: `1.253953 s`。
- 実ログの`0.291 s`との一致は要求していない。test process内の初回関数compileを含むが、nodeが空くのを待たず4cycleで回数を消費する性質は同じ。
- 1回目artifact: `/tmp/syncopade-busy-drop-step3.D7UXcx/`。
- 1回目CSV SHA-1: `9b1edc52af024c18fae34331c520ef632f12c851`。
- 2回目artifact: `/tmp/syncopade-busy-drop-step3-repeat.GV0zsB/`。
- 2回目CSV SHA-1: `a786d12c6bad206febe07b1638d42956339d5168`。
- cleanup後、偽worker listenerとJulia processは残らなかった。
- `git diff --check`と新規testのwhitespace checkはerrorなし。
- repository log SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`のまま。

### Step 3結論

現行conductorはworkerの正常な未受理応答`ERROR|BUSY`を一般配送故障として扱い、nodeを`down`へ変更し、通常のfailure retryを消費する。空き状態と判断されるたびに同じtaskを再配送し、4回目で通知なしdropの直前まで進むことを、状態巻き戻りとは分けて確認した。

---

## Step 4: TASK_DROPPED後に親へ終了通知がないことを再現する — 未着手

### 目的

conductorが受付済みtask IDを破棄した後、親のcallback listenerへ成功・失敗のどちらも届かず、親から見た待機対象が残ることを確認する。

### 対象ファイル

- `test/reproduction_conductor_silent_drop.jl`（新規候補）
- `syncopadeClient.jl`（読取り・呼出しのみ）
- `syncopadeConductor.jl`（読取り・呼出しのみ）
- このTodo

### 完了条件

- loopback上に親のcallback listenerを先に起動する。
- 親が保持するtask IDと、dropされる`ConductorTask.task_id`が一致する。
- `requeue_with_retry!`の上限超過によりqueueからタスクが消える。
- 一時logには該当task IDの`TASK_DROPPED`が1件記録される。
- bounded wait内にcallback接続が来ない。
- 「通知がない」を無期限待機ではなく、短い試験期限で判定する。

### 検証方法

1. callback listenerと、retry上限に達したtaskを用意する。
2. `requeue_with_retry!`を呼び、queue length 0とdrop logを確認する。
3. callback listenerを短い期限だけ待ち、接続がないことを確認する。
4. task ID、queue、log、listener結果を一つのreceiptへ記録する。
5. listener、非同期task、portを必ず終了する。

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 5: lan100の単一server構成で実TCP前提を確認し証拠を統合する — 未着手

### 目的

このPCの`192.168.100.30`上で公式conductor/server wrapperを使用し、偽worker試験が前提としたserver排他、BUSY応答、終了後の再受理と、conductor経由の4タスク運転を実TCPで確認する。

このStepで自然raceの再発を必須条件にはしない。状態巻き戻りの正本はStep 2の順序固定試験とし、実networkでは観測結果をそのまま記録する。

### 対象ファイル

- `scripts/run_conductor.jl`（実行のみ）
- `scripts/run_server.jl`（実行のみ）
- `test/integration_server_busy_rejection.jl`（既存試験を使用）
- 必要な再現runner（repository外）
- このTodo

### 固定環境

- `SYNCOPADE_NODE_PROFILE=lan100`
- `SYNCOPADE_WIRED_PREFIX=192.168.100.`
- conductor: `192.168.100.30:9030`
- server: `192.168.100.30:8030`
- conductor log: repository外の一時file
- task数: 4

### 完了条件

- 起動前に8030/9030が空いている。
- conductorとserverが指定endpointで継続起動する。
- conductorのidle node集合が`192.168.100.30:8030`の1件だけである。
- serverは先行タスク実行中の追加要求へ`ERROR|BUSY`を返し、job IDを発行しない。
- 先行タスク終了後、次の要求を正常受理する。
- conductor経由で短いタスクを4件投入し、task ID、job ID、callback、DONE、BUSY、retry、dropを実測のまま記録する。
- 自然raceが出ても出なくても、Step 2〜4の決定的再現結果と矛盾しない形で整理する。
- 全process・listenerを終了し、repository logが不変である。

### 検証方法

1. IP、port、既存process、repository log identityを事前確認する。
2. conductor/serverを一時log付きで起動する。
3. `STATUS`と`LIST`でserver 1本だけの構成を確認する。
4. 既存BUSY拒否試験でserver排他と再受理を確認する。
5. 4タスクをconductor経由で投入し、全イベントを一時logへ記録する。
6. Step 1〜5の結果を、観測事実とコードからの説明に分けてreceiptへまとめる。
7. process、port、temporary task、repository log identityを終了確認する。

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## 完了時の引渡し

- 各再現scriptの実行commandとexit code。
- 各Stepの`PASS_REPRODUCED`または未再現結果。
- task ID、retry、node状態、worker要求回数、job ID発行数、callback有無。
- repository外のconductor event log、stdout、stderr、receiptのpathとhash。
- 起動process、listener、portのcleanup結果。
- `logs/conductor_events.csv`が作業前後で不変である証拠。
- 修正Todoへ渡す、確定原因・未確定事項・必要な回帰試験一覧。

## 現在状態

- Todo作成のみ。
- Step 1〜5はすべて未着手。
- production/test実装、再現試験、commit、pushは開始していない。
- 先生との相互確認により、強化C進行でStep 1から開始する。
