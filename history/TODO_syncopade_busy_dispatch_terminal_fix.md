# Syncopade BUSY配送・終端通知 修正 Todo（完了記録）

- 実装修正・統合試験完了commit: `eb13d14d7c707c972b01d8a94091befa68858f26`
- 完了時点のbranch: `master`、`origin/master`と一致
- 本記録の退避と文書整理、version更新は上記commitの後続作業として分離する

## 目的

修正前再現試験で分離した次の連鎖を、原因ごとに修正する。

1. 遅れて到着した`STATUS|idle`が、後から成立した配送状態を上書きする。
2. workerの正常な`ERROR|BUSY`拒否を故障として数え、短時間で再試行上限を消費する。
3. conductorが受付済みタスクを実行せずに打ち切っても、親がtask ID付きの終端状態を取得できない。

修正は、状態管理、配送予約、BUSY判定、終了通知を一括で書き換えず、失敗原因を特定できる小さなStepに分ける。

Todo作成と確認はStep 1に含めない。先生とこのTodoを相互確認するまでは、Step 1を開始しない。

## 正本と修正前evidence

- 改訂依頼書: `REQUEST_syncopade_busy_dispatch_and_terminal_notification.md`
- 修正前再現記録: `history/TODO_syncopade_pre_fix_busy_dispatch_reproduction.md`
- 修正前baseline: tag `v0.1.3`、commit `8dfcc135b9c87c13950757cc344fb398a98fe708`
- 修正作業Todo作成時HEAD: `d1c84bd14a31c7d0e05e76c3e13b338f5d5eaa47`
- 正本ログ: `/Volumes/syncopade_nfs/conductor_events.csv`
- 対象task ID: `5799dcc7-078f-431d-abe9-f323c5724c82`
- 修正前の決定的再現:
  - 古い`idle`による`busy -> idle`巻き戻り: 19/19 assertions pass
  - `ERROR|BUSY` 4回による再試行消費・破棄: 39/39 assertions pass
  - `TASK_DROPPED`後に親へ通知なし: 9/9 assertions pass
- `lan100`実TCP確認では自然な状態競合は発生しなかった。修正判定は応答順を固定した試験を正本とする。

## 修正後に守る不変条件

nodeの現在割当てを

\[
A(n) \in \{\varnothing, (task\_id, job\_id?)\}
\]

とする。`job_id`はworker受付前には未確定でもよいが、1 nodeが同時に所有できる割当ては最大1件とする。

- `A(n) != \varnothing`の間、状態確認の応答だけでnodeを`idle`へ戻さない。
- node選択と配送予約を同じ同期境界で行い、同じidle nodeを二つのtaskへ予約しない。
- worker受付後は、対応する`task_id`と`job_id`が一致する`DONE`だけが割当てを解放できる。
- `ERROR|BUSY`は「workerが正常に応答し、今回のtaskを受理しなかった」結果として扱う。
- `ERROR|BUSY`ではnodeを`down`にせず、通常の配送失敗回数を増やさない。
- worker受付応答のtimeoutは受付成否不明として扱い、別nodeへ無条件再配送しない。
- conductorが受け付けたtaskは、成功、worker実行失敗、conductor打切り、または受付成否不明のいずれかの終端状態をtask IDで確認できる。
- conductorからの終端通知はtask ID単位で高々1回だけ確定し、親はtask IDで重複を除外できる。

## このTodoで採用する仕様

先生との確認内容を次の前提として固定する。変更する場合はStep 1開始前にTodo全体を直す。

### worker受付までの待機期限

- conductorがtaskを受け付けてから、workerが`OK|STARTED|job_id`で受理するまでの待機期限を設ける。
- 既定値は`4 h = 14400 s`とする。50分程度の計算が先行している場合にも、後続taskがqueueで待てる長さとして設定する。
- 既定値はconductorの環境変数で変更可能にし、さらに投入ごとに公開client APIから上書きできるようにする。
- workerが受理した時点でこの待機期限の対象外とする。受理後の計算実行時間を制限・中断するtimeoutは本Todoでは導入しない。
- 単体試験では短い期限と単調時計を引数注入し、実時間で4時間待たずに境界を確認する。
- BUSYまたはidle nodeなしの間はtaskを保持し、期限前には破棄しない。
- 期限到達時、worker未受理が確定していれば`QUEUE_TIMEOUT`、受付成否不明なら`DISPATCH_OUTCOME_UNKNOWN`として区別する。

### worker受付応答timeout

- timeout後に同じtaskを別nodeまたは同じnodeへ自動再配送しない。
- taskを`dispatch_unknown`として保持し、対応する遅延受付応答または`DONE`を期限まで照合する。
- 期限まで確定できなければ、実行されなかったとは断定せず`DISPATCH_OUTCOME_UNKNOWN`で終端する。
- conductor再起動をまたぐ永続的なexactly-once保証は本Todoの対象外とする。

### task ID付き結果

- task IDとjob IDを別々に含む新しい結果形式を採用する。これは監査logの追加ではなく、親へ返す通信契約の追加である。
- conductor経由の結果にはconductorの`task_id`とworkerの`job_id`を別フィールドで含める。
- worker未受理のconductor終端失敗では`job_id`を空欄にできる。
- 既存の直接worker投入用`RESULT|job_id|...`は維持する。
- conductor経由ではversionを区別できる新しい結果payloadを使用し、公開clientは旧形式と新形式を混同せず解析する。
- 正確なpayload名とフィールド順は、Step 9 Phase 2で既存checksum規約と後方互換性を照合して固定する。

### 終端状態の回収

- callback送信だけに依存せず、conductorはtask IDごとの終端状態をprocess存続中は保持する。
- 親は公開client APIからtask IDを指定して状態照会できる。
- callback失敗時も、状態照会により終端理由を回収できる。
- 先生との確認どおり、conductor再起動後のtask状態永続化は本Todoの対象外とする。

### 監査log

- 修正に必要な監査eventとfieldの追加は灯子が設計する。
- 少なくとも、古いSTATUSの不適用、node予約、BUSY未受理、待機期限到達、受付成否不明、不一致DONE、terminal確定、callback送信成否を区別して記録する。
- event名とfieldは各該当StepのPhase 2で固定し、同じ意味を複数のevent名へ分散させない。
- testではrepository外の一時logを使い、`logs/conductor_events.csv`の先生の既存差分には書き込まない。

## 今回やらないこと

- `192.168.12.*`の実運用conductor/serverへの接続、停止、配送
- sibling repositoryである`Julia_script_ManipMDO_ICRA2027`の変更
- server capacityを1より増やす変更
- serverの既存atomic busy受付を緩める変更
- LIFO/FIFO方針の無関係な変更
- conductor状態のdisk永続化、再起動復旧、分散合意
- checksum方式の変更、暗号化、認証機能の追加
- 無関係なrefactor、命名整理、性能最適化
- version更新、tag作成、release作業
- `logs/conductor_events.csv`の先生の既存差分への変更、stage、復元

## 共通進行・停止条件

- 進行方式は、このTodoの相互確認後に先生が指定する。
- 一度に進めるのは1 Step、その中でもPhase 1→2→3→4を一つずつとする。
- 各StepのPhase 1で実装方針、Phase 2で関数仕様・入出力・副作用、Phase 3で実装、Phase 4で検証を記録する。
- source変更は各StepのPhase 3だけで行う。
- 各StepのPhase 4が成功した後、そのStepの対象差分だけをcommit/pushする。
- error、test failure、想定外のprotocol差、既存dirty fileの変化、listener/processのcleanup失敗があれば、そのPhaseで停止する。
- Step追加・分割・削除・順序変更、前提変更、仕様変更、完了条件変更が必要なら作業を止め、Todo全体の見直しを先生へ提案する。
- 強化C進行が指定された場合も、自律修正できるのは文字間違い、構文ミス、Markdown改行・空白など、Todoの意味を変えない灯子の局所的なミスだけとする。
- repository外の一時logは`mktemp -d`で作り、正常・異常終了のどちらでも起動processとlistenerを片付ける。

---

## Step 1: node状態と割当ての原子的な遷移を定義する — 完了

### 目的

nodeの単純な状態記号だけでなく、状態の世代と現在のtask/job割当てを同じlockで管理できる最小内部表現を作る。まだmonitor、配送、DONEの本処理には接続しない。

### 対象ファイル

- `syncopadeConductor.jl`
- `test/unit_conductor_node_state.jl`（新規候補）
- このTodo

### 完了条件

- nodeごとに状態、更新世代、割当てtask ID、任意のjob IDを保持できる。
- idle nodeの予約、受付job IDの確定、状態確認結果の条件付き反映、一致する割当ての解放を同じ同期境界で実行できる。
- 不一致task/jobによる解放と、古い世代の状態反映は状態を変えない。
- 既存のnode状態取得・設定を使う呼出し元は、このStep終了時点でも従来どおり動く。

### 検証方法

1. networkを使わない単体試験で`idle -> reserved -> busy -> idle`を確認する。
2. 同じidle nodeへの二重予約が片方だけ成功することを確認する。
3. 古い世代の更新、不一致task ID、不一致job IDが無視されることを確認する。
4. `test/unit_conductor_queue.jl`を含む既存の軽量試験を実行する。

### Phase 1: 実装方針をまとめる — 完了

- 現在の`Dict{Tuple{String,Int},Symbol}`を、同じendpoint keyの`NodeRuntimeState`へ置き換える。recordは`state`、単調増加する`generation`、`task_id`、`job_id`を持つimmutableな内部型とし、lock外へ参照を返しても後から内容が変わらない構造にする。
- 未割当ては空文字列で表し、`reserved`はtask IDあり・job IDなし、worker受付後の`busy`はtask IDとjob IDの両方ありとする。外部STATUSで観測した`busy`は割当てIDなしを許す。
- 新しい内部操作は、snapshot取得、世代一致時だけの観測反映、idleからのtask予約、同じtask予約へのjob ID確定、task/job一致時だけの解放に分ける。各操作は`node_states_lock`を1回だけ取得し、判定と更新を同じlock区間で行う。
- 更新はrecord全体の置換とし、成立した更新ごとに`generation`を1増やす。古い世代、不一致task、不一致job、二重予約はrecordを変更せず失敗を返す。
- 既存`get_node_state`はrecordの`state`だけを返す互換入口として残す。既存`set_node_state!`もStep 1では残し、状態更新時に世代を進め、`idle`または`down`への従来更新では割当てを空にする。後続Stepでmonitor、dispatch、DONEを専用操作へ順に置き換える。
- 現在`node_states`を直接読むLIST処理だけは、recordの`state`を読むよう追従させる。monitor、配送、DONEの挙動変更はこのStepへ混ぜない。
- 単体試験はnetworkを使わず、正常遷移、二重予約拒否、古い世代の観測拒否、task/job不一致解放拒否、record snapshotの不変性を確認する。
- 監査logは既存`NODE_STATE_CHANGED`を維持する。新しい遷移固有eventの追加は、その遷移をproduction経路へ接続するSteps 2〜4で行う。
- `logs/conductor_events.csv`へ書かないよう、試験processではinclude前に一時log pathを設定し、終了時にwriterとglobal stateを片付ける。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### `NodeRuntimeState`

- fields: `state::Symbol`、`generation::UInt64`、`task_id::String`、`job_id::String`。
- 未登録nodeの論理値は`NodeRuntimeState(NODE_DOWN, 0, "", "")`とする。読取りだけでは辞書へ追加しない。
- `NODE_RESERVED = :reserved`を内部状態へ追加する。workerのSTATUS応答が返す状態ではなく、conductor内だけの配送予約状態とする。
- recordはimmutableとし、更新前に取得したsnapshotのfieldsは後続更新で変化しない。

#### `get_node_runtime_state(node::NODES)::NodeRuntimeState`

- endpoint keyで現在recordをlock内取得し、未登録なら上記の初期値を返す。
- network、log、辞書追加を行わない。

#### `get_node_state(node::NODES)::Symbol`

- `get_node_runtime_state(node).state`だけを返す既存互換APIとする。
- network、log、状態変更を行わない。

#### `set_node_state!(node::NODES, state::Symbol)::Nothing`

- 既存互換の無条件更新入口として残し、更新のたびにgenerationを1増やす。
- `state`が`NODE_IDLE`または`NODE_DOWN`ならtask/job割当てを空にする。`NODE_BUSY`なら現在の割当てを維持する。
- stateが変わった場合だけ既存`NODE_STATE_CHANGED`を記録する。割当てまたはgenerationだけの変更では、このStepで新eventを増やさない。
- 互換入口で許可する`NODE_IDLE`、`NODE_BUSY`、`NODE_DOWN`以外は`ArgumentError`とし、内部専用`NODE_RESERVED`は予約関数からだけ設定する。

#### `apply_observed_node_state!(node::NODES, state::Symbol, expected_generation::UInt64)::Bool`

- worker状態確認の結果を適用する内部関数とする。
- 現在generationが`expected_generation`と一致し、task割当てが空の場合だけ状態を置換し、generationを1増やして`true`を返す。
- 世代不一致または割当てありでは何も変更せず`false`を返す。
- 許可する観測値は`NODE_IDLE`、`NODE_BUSY`、`NODE_DOWN`だけとし、`NODE_RESERVED`は`ArgumentError`とする。
- Step 1ではproductionの状態確認経路からまだ呼ばない。

#### `try_reserve_node!(node::NODES, task_id::String)::Bool`

- 空でないtask IDを要求する。
- 現在状態が`NODE_IDLE`かつtask/job割当てが空の場合だけ、`NODE_RESERVED`、指定task ID、空job IDへ置換し、generationを1増やして`true`を返す。
- 条件不一致ではrecordを変えず`false`を返す。
- worker接続、queue変更、task retry変更を行わない。

#### `mark_node_running!(node::NODES, task_id::String, job_id::String)::Bool`

- 空でないtask IDとjob IDを要求する。
- 現在状態が`NODE_RESERVED`、task ID一致、job ID未確定の場合だけ`NODE_BUSY`と指定job IDへ置換し、generationを1増やして`true`を返す。
- 条件不一致ではrecordを変えず`false`を返す。

#### `release_node_assignment!(node::NODES, task_id::String, job_id::String; next_state::Symbol=NODE_IDLE)::Bool`

- 現在のtask IDとjob IDが引数に完全一致し、task IDが空でない場合だけ割当てを空にし、`next_state`へ置換してgenerationを1増やし、`true`を返す。
- `next_state`は`NODE_IDLE`または`NODE_DOWN`だけを許可する。
- task不一致、job不一致、割当てなしではrecordを変えず`false`を返す。
- Step 1ではproductionのDONE経路からまだ呼ばない。

#### 単体試験と副作用境界

- file: `test/unit_conductor_node_state.jl`。
- include前に`SYNCOPADE_CONDUCTOR_LOG`をrepository外の一時pathへ設定する。
- 未登録初期値、legacy set/get、正常予約・受付・解放、二重予約、古い世代、不一致task/job、snapshot不変性、invalid stateを確認する。
- `finally`でlog writerを停止し、`node_states`をlock内で空にする。
- 実行後に一時log以外のfile、listener、processを残さない。

### Phase 3: 実装する — 完了

- `NodeRuntimeState`と内部状態`NODE_RESERVED`を追加し、`node_states`のvalueを状態recordへ変更した。
- 未登録nodeの副作用なしsnapshot取得、legacy state取得・設定、世代一致観測反映、idle予約、job ID確定、一致割当て解放を実装した。
- 各遷移の判定とrecord置換を`node_states_lock`内で一体化し、成立しない操作はrecordを変更せず`false`を返すようにした。
- legacy `set_node_state!`は`NODE_IDLE`、`NODE_BUSY`、`NODE_DOWN`だけを受け付け、既存呼出しの戻り値と状態取得契約を維持した。
- LISTの直接辞書参照を`NodeRuntimeState.state`へ追従させた。monitor、dispatch、DONEの呼出し経路はまだ変更していない。
- `test/unit_conductor_node_state.jl`を追加し、一時log、global state cleanupを含むnetworkなしの単体試験を実装した。
- `git diff --check`で検査できる範囲のwhitespace不整合はない。機能検証はPhase 4で行う。

### Phase 4: テストまたは検証を行う — 完了

- `julia --startup-file=no --project=. test/unit_conductor_node_state.jl`: exit `0`、`55 / 55 pass`、marker `STEP1_RESULT=PASS_NODE_RUNTIME_STATE`。
- 未登録読取りは辞書を変更せず、legacy set/get、`idle -> reserved -> busy -> idle`、二重予約拒否、古い世代拒否、task/job不一致拒否、snapshot不変性、invalid stateを確認した。
- repository外logで`test/unit_conductor_queue.jl`を実行し、exit `0`、`17 / 17 pass`。
- Step 1でproduction経路の挙動を変えていないことを確認するため、修正前再現3本も独立processで再実行した。
  - stale idle: exit `0`、`19 / 19 pass`、artifact `/tmp/syncopade-step1-stale.1WStFj`。
  - BUSY retry/drop: exit `0`、`39 / 39 pass`、artifact `/tmp/syncopade-step1-busy.3gNYI3`。
  - silent drop: exit `0`、`9 / 9 pass`、artifact `/tmp/syncopade-step1-silent.XHcp96`。
- `git diff --check`はerrorなし。
- repository log SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`のままで、先生の既存差分を変更していない。
- 起動した試験processとlistenerの残留はない。

### Step 1結論

node状態、世代、task/job割当てを一つのrecordとして原子的に更新できる内部境界が成立した。既存の状態取得・設定、queue、修正前再現経路は維持されており、STATUS、dispatch、DONEへの接続は後続Stepへ分離できている。

---

## Step 2: 古いSTATUS応答を適用しない — 完了

### 目的

状態確認開始後にnodeの状態または割当てが進んだ場合、その確認結果を古い観測として破棄する。

### 対象ファイル

- `syncopadeConductor.jl`
- `test/reproduction_conductor_stale_idle.jl`（修正後回帰試験へ変更・改名候補）
- このTodo

### 完了条件

- `refresh_states_until_idle!`とmonitorの状態反映が、確認開始時の世代を照合する。
- STATUS要求後にtask予約またはbusy化したnodeへ、遅れた`STATUS|idle`を適用しない。
- 破棄した観測はnode、取得時世代、現在世代、観測状態を監査logへ残す。
- 未割当てで世代が変わっていないnodeには、従来どおり`idle`、`busy`、`down`を反映できる。

### 検証方法

1. 修正前の固定順序試験を反転し、最終状態が`busy`のままであることを確認する。
2. `STATUS request < busy確定 < 遅延idle response`の順序を時刻と履歴で確認する。
3. 古い観測を破棄したlogが1件、`busy -> idle`変更logが0件であることを確認する。
4. 通常の未割当てnodeのstatus refreshが壊れていないことを確認する。

### Phase 1: 実装方針をまとめる — 完了

- 状態確認値を書き戻すproduction経路を再確認し、SUBMIT後の`refresh_states_until_idle!`、定期`monitor_nodes`、cache clear成功後の再確認に加え、cache clear失敗時の`down`反映も世代照合対象とする。同じ古い観測で割当てを壊せる経路を残さない。
- 各network要求を開始する直前に`NodeRuntimeState.generation`をsnapshotし、応答後はStep 1の`apply_observed_node_state!`だけから適用する。状態取得とnetwork I/Oの全時間をlockで囲まない。
- 複数nodeの並列STATUS確認は、nodeごとの開始時generationと観測状態を対応させた結果を返す。配列順だけでなく同じnodeとtokenを一組にして扱う。
- 観測適用に失敗した場合は現在recordを再取得し、`NODE_OBSERVATION_IGNORED`を記録する。既存CSV列の`task_id`、`job_id`、`state_from`、`state_to`、`status`、`error`を使い、`error`へ期待generation、現在generation、不適用理由を入れる。CSV列自体は増やさない。
- `refresh_states_until_idle!`の戻り値は、古い応答にidleが含まれたかではなく、適用判定後の現在recordにidle nodeが存在するかで決める。
- monitor表示も観測値でなく適用後の現在状態を表示し、不適用時は観測値が無視されたことを同じ行で区別する。
- cache clear失敗の`down`反映にはcache clear開始前のgeneration、成功後のSTATUS反映にはそのSTATUS開始直前のgenerationを使用する。途中で予約・配送が進んだ場合は状態を巻き戻さない。
- 修正前試験を`test/regression_conductor_stale_idle.jl`へ改名し、同じ明示順序のまま期待値を反転する。古いidle応答後も最終状態`busy`、refresh戻り値`false`、`busy -> idle` log 0件、不適用event 1件を要求する。
- Step 2では手動`set_node_state!(NODE_BUSY)`で世代を進める。node予約と実配送の接続はStep 3へ残し、BUSY、retry、DONEの挙動は変更しない。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### `NodeObservation`

- fields: `node::NODES`、`state::Symbol`、`expected_generation::UInt64`。
- `state`はnetwork要求から得た`NODE_IDLE`、`NODE_BUSY`、`NODE_DOWN`のいずれかとする。
- nodeと開始時generationを同じ値に保持し、parallel結果の取り違えを防ぐ。

#### `probe_node_observation(node::NODES; timeout=DEFAULT_STATUS_TIMEOUT)::NodeObservation`

- 最初に`get_node_runtime_state(node)`でgenerationを取得し、直後に既存`probe_node`を呼ぶ。
- timeout、接続失敗、不正STATUSは既存`probe_node`どおり`NODE_DOWN`観測として返す。
- node状態辞書への書込みとlog出力は行わない。

#### `probe_nodes_parallel(nodes::Vector{NODES}; timeout=DEFAULT_STATUS_TIMEOUT)::Vector{NodeObservation}`

- nodeごとに`probe_node_observation`を非同期実行し、入力順と同じ順の観測を返す。
- 個別taskの予期しない例外も、そのtask開始時generationと同じnodeを持つ`NODE_DOWN`観測へ変換する。
- 状態辞書への書込みは行わない。

#### `apply_node_observation!(observation::NodeObservation; source::Symbol)::Bool`

- Step 1の`apply_observed_node_state!`へnode、state、expected generationを渡す。
- 適用成功時は`true`を返し、追加eventは記録しない。stateが変化した場合の既存`NODE_STATE_CHANGED`はStep 1 helperが記録する。
- 不適用時は現在recordを再取得し、`NODE_OBSERVATION_IGNORED`を1件記録して`false`を返す。
- eventの`task_id`/`job_id`は現在割当て、`state_from`は現在状態、`state_to`は観測状態、`status`は`source`とする。
- `error`は`reason=generation_changed`または`reason=active_assignment`、`expected_generation=<n>`、`current_generation=<n>`を空白区切りで持つ。
- network、queue、retry、割当て変更は行わない。

#### `refresh_states_until_idle!`

- 全`NodeObservation`へ`source=:refresh`で適用を試みる。
- 全適用処理後、入力nodesの現在状態を再取得し、1件以上`NODE_IDLE`なら`true`、なければ`false`を返す。
- 古い`NODE_IDLE`観測そのものを戻り値へ使用しない。

#### `monitor_nodes`

- 全観測へ`source=:monitor`で適用を試みる。
- 表示する主状態は適用後の`get_node_state(node)`とする。
- 不適用時だけ`observed=<state> ignored`を付記する。

#### `clear_all_node_caches`

- cache clear非同期taskを作る前に各nodeのgenerationを保存する。
- cache clear失敗時は保存したgenerationを使う`NODE_DOWN`観測を`source=:cache_clear`で適用する。
- cache clear成功時はその後に`probe_node_observation`を開始し、`source=:cache_status`で適用する。
- cache clearの成功・失敗集計自体は状態観測の適否にかかわらず従来どおり記録する。

#### 修正後回帰試験

- fileを`test/reproduction_conductor_stale_idle.jl`から`test/regression_conductor_stale_idle.jl`へ改名する。
- worker request、busy設定、遅延idle responseの明示順序と時刻比較は維持する。
- refresh戻り値は`false`、最終recordは`NODE_BUSY`かつbusy設定後のgenerationのままとする。
- 一時CSVは`down -> idle`、`idle -> busy`を各1件含み、`busy -> idle`を含まない。
- `NODE_OBSERVATION_IGNORED`は1件で、`source=refresh`、観測`idle`、現在`busy`、期待generationと現在generationが異なることを確認する。
- markerは`STEP2_RESULT=PASS_STALE_IDLE_IGNORED`へ変更する。

### Phase 3: 実装する — 完了

- `NodeObservation`、単node観測、parallel観測、世代照合付き適用と不適用監査eventを実装した。
- `refresh_states_until_idle!`は全観測適用後の現在recordからidle有無を返すよう変更した。
- `monitor_nodes`は適用後状態を表示し、古い観測を無視した場合だけ観測値を付記するよう変更した。
- cache clear開始前generationと、成功後STATUS開始前generationを保存し、成功・失敗どちらの状態反映も条件付き観測へ接続した。
- `test/reproduction_conductor_stale_idle.jl`を`test/regression_conductor_stale_idle.jl`へ改名し、遅延idleを無視する正方向の期待値へ反転した。
- BUSY分類、dispatch予約、retry、DONEのproduction処理には変更を加えていない。
- `git diff --check`で検査できる範囲のwhitespace不整合はない。機能検証はPhase 4で行う。

### Phase 4: テストまたは検証を行う — 完了

#### 初回検証と強化C補正

- 初回はproductionの最終状態、refresh戻り値、不適用eventまで正しかったが、試験がCSV全体から`"busy","idle"`を検索し、`NODE_OBSERVATION_IGNORED`の「現在busy・観測idle」を状態変更と誤認して1 assertion失敗した。
- production codeやTodo前提の問題ではなく、灯子が試験の検索対象eventを限定しなかった局所ミスだった。
- 強化C規則に従い、`NODE_STATE_CHANGED`行だけから状態遷移を検査するよう修正し、Phase 4を最初から再実行した。

#### 最終検証

- `test/regression_conductor_stale_idle.jl`を2回連続実行し、いずれもexit `0`、`26 / 26 pass`、marker `STEP2_RESULT=PASS_STALE_IDLE_IGNORED`。
- 両実行で`STATUS request < busy確定 < 遅延idle response`の明示順序を確認した。
- 遅延idle後のrefresh戻り値は`false`、最終状態は`NODE_BUSY`、generationはbusy確定時から不変だった。
- 両CSVは`NODE_STATE_CHANGED`の`down -> idle`、`idle -> busy`を各1件含み、`busy -> idle`は0件だった。
- 両CSVは`NODE_OBSERVATION_IGNORED`を1件含み、現在`busy`、観測`idle`、source `refresh`、reason `generation_changed`、expected/current generation `1/2`だった。
- 1回目artifact: `/tmp/syncopade-step2-stale-retry.OL4yxh`、CSV SHA-1 `638aa1d114b014ab40bbecb2823600808e832aea`。
- 2回目artifact: `/tmp/syncopade-step2-stale-repeat.72rT9n`、CSV SHA-1 `73ed453ba0e9f45ceb39a66d632571319ddfa926`。
- `test/unit_conductor_node_state.jl`: exit `0`、`55 / 55 pass`。
- `test/unit_conductor_queue.jl`: exit `0`、`17 / 17 pass`。
- `git diff --check`はerrorなし。
- repository log SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`のままで、先生の既存差分を変更していない。

### Step 2結論

状態確認開始後に状態世代が進んだ場合、遅れて返ったidle観測は現在状態へ適用されない。固定順序で`busy -> idle`巻き戻りが消え、古い観測だけが監査eventへ残ることを2回確認した。

---

## Step 3: node選択と配送予約を一体化する — 完了

### 目的

idle nodeを選んでからworkerへ接続するまでの間に、同じnodeが別taskから選ばれないよう、選択時点でtask ID付き予約を確定する。

### 対象ファイル

- `syncopadeConductor.jl`
- `test/unit_conductor_dispatch_reservation.jl`（新規候補）
- `test/unit_conductor_queue.jl`
- このTodo

### 完了条件

- node選択と`idle -> reserved(task_id)`が同じlock区間で行われる。
- 配送開始前に予約が見え、LISTと別の配送処理からidleとして選ばれない。
- worker受付成功時は同じ予約へjob IDを記録する。
- 受付前に確定した通信失敗では、そのtaskの予約だけを定めた失敗状態へ遷移させる。
- 既存の右から左へのnode選択順は維持する。

### 検証方法

1. 同時に二つの予約処理を開始し、1 nodeには一方だけが予約成功することを確認する。
2. 予約中nodeがLISTと次のnode選択に現れないことを確認する。
3. 受付成功後にtask IDとjob IDが同じ割当てへ保存されることを確認する。
4. 既存queue testとconductor wrapper起動試験を実行する。

### Phase 1: 実装方針をまとめる — 完了

- 右から左へidle nodeを探す処理と`NODE_RESERVED/task_id`へのrecord置換を、`node_states_lock`の同じ取得区間で実行する`reserve_idle_node_right_to_left!`へまとめる。
- 既存`pick_idle_node_right_to_left`は読取り専用互換helperとして残すが、productionの`dispatch_queued_tasks`からは使わない。
- 予約成立後は既存`NODE_STATE_CHANGED`に加え、task ID付き`NODE_RESERVED` eventを記録する。別taskとの二重予約またはidleなしでは状態もlogも変更しない。
- LISTのidle抽出を`idle_node_endpoints()`へ分離し、予約中nodeを返さないことをnetworkなしで直接検証できるようにする。wireの`NODES|...`形式は変えない。
- `dispatch_queued_tasks`はqueueからtaskを取り出した後、atomic予約helperでnodeを取得する。予約できなければ従来どおり同じtaskをretry増加なしでqueueへ戻し、そのcycleを終了する。
- `dispatch_to_worker`は自taskの予約が存在することを送信前条件とする。`OK|STARTED|job_id`受信後は`mark_node_running!`で同じ予約へjob IDを確定する。
- 受付成功後に予約確定が失敗した場合も、workerが受理済みのtaskを再投入しないよう配送結果自体は成功として扱い、`DISPATCH_ASSIGNMENT_CONFLICT`へ現在recordとjob IDを記録する。早いDONEとの厳密な照合はStep 4で解消する。
- 受付前の例外では、task ID一致・job ID未確定の自予約だけを`NODE_DOWN`へ解放する。他taskへ割当てが変わっていた場合は無条件`set_node_state!(NODE_DOWN)`を行わず、`DISPATCH_RESERVATION_RELEASE_FAILED`を記録する。
- Step 3では`ERROR|BUSY`はまだ一般例外なので、従来どおり予約解放後`down`とfailure retryになる。分類変更はStep 5〜6へ残す。
- 単体試験では、右優先、LIST除外、逐次・同時二重予約拒否、正常ACK後のtask/job保存、受付失敗後に自予約だけが解放されることを確認する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### `reserve_idle_node_right_to_left!(nodes::Vector{NODES}, task_id::String)::Union{Nothing,NODES}`

- 空でないtask IDを要求し、空なら`ArgumentError`とする。
- `node_states_lock`を1回取得し、`reverse(nodes)`順で`NODE_IDLE`かつtask/job IDが空の最初のrecordを探す。
- 見つかったrecordを`NODE_RESERVED`、指定task ID、空job ID、generation + 1へ置換し、そのnodeを返す。
- 見つからなければ何も変更せず`nothing`を返す。
- 予約成功時だけ`NODE_STATE_CHANGED`の`idle -> reserved`と`NODE_RESERVED`を各1件記録する。`NODE_RESERVED`にはtask IDとnode endpointを含める。
- queue、retry、network I/Oは変更しない。

#### `idle_node_endpoints()::Vector{String}`

- `node_states_lock`内で`runtime_state.state == NODE_IDLE`のentryだけを`ip:port`へ変換して返す。
- `NODE_RESERVED`、`NODE_BUSY`、`NODE_DOWN`は返さない。
- state、generation、割当て、queue、logを変更しない。

#### `node_reserved_for_task(node::NODES, task_id::String)::Bool`

- 現在recordが`NODE_RESERVED`、task ID一致、job ID空なら`true`を返す読取り専用helperとする。
- network、state、logを変更しない。

#### `dispatch_to_worker(task, node)`の予約契約

- network接続前に`node_reserved_for_task(node, task.task_id)`を要求し、不成立なら`ArgumentError`を送出して通信しない。
- 正常ACKで得たjob IDを`mark_node_running!`へ渡す。
- mark成功時は従来どおり`DISPATCH_OK`を記録して`true`を返す。
- mark不成立でもworker受付は成功済みなので、`DISPATCH_ASSIGNMENT_CONFLICT`へtask ID、job ID、現在state/generation/割当てを記録し、`DISPATCH_OK`と`true`を返す。queueへ戻さない。
- ACK前の例外では`release_node_assignment!(node, task.task_id, ""; next_state=NODE_DOWN)`を呼ぶ。成功時は自予約だけが消える。
- release不成立時は`DISPATCH_RESERVATION_RELEASE_FAILED`へ現在recordを記録し、他割当てを変更しない。
- 例外経路は既存`DISPATCH_FAILED`を記録して`false`を返す。

#### `dispatch_queued_tasks`の選択契約

- `pick_idle_node_right_to_left`の代わりに`reserve_idle_node_right_to_left!`を呼ぶ。
- `nothing`なら取り出したtaskをそのままqueue末尾へ戻し、`NO_IDLE_REQUEUE`を記録してreturnする。
- nodeを得た場合だけ`dispatch_to_worker`を呼ぶ。
- `false`の場合のfailure retryはStep 3では既存どおり維持する。

#### 単体試験

- file: `test/unit_conductor_dispatch_reservation.jl`。
- `--threads=4`で実行し、1 nodeへ同時に二つのtask IDから予約を試みて成功が1件だけであることを確認する。
- 3 nodesのidle/busy配置で右端idleが選ばれ、予約後に`idle_node_endpoints()`から除外されることを確認する。
- 制御workerの正常ACKでrecordが`busy/task_id/job_id`になることを確認する。
- 制御workerの現行BUSY例外で自予約だけが`down`へ解放され、taskがretry 1でqueueへ戻ることを確認する。
- 一時logから`NODE_RESERVED`、`DISPATCH_OK`、`DISPATCH_FAILED`をtask IDごとに照合する。
- `finally`でworker、log writer、queue、node stateをcleanupする。

### Phase 3: 実装する — 完了

- `reserve_idle_node_right_to_left!`を追加し、右から左のidle探索とtask ID付き予約を一つの`node_states_lock`区間へ統合した。
- 予約済みnode判定とidle endpoint抽出を追加し、LISTを共通抽出helperへ接続した。
- `dispatch_queued_tasks`をread-only pickからatomic予約へ変更した。
- `dispatch_to_worker`へ予約precondition、正常ACK後のjob ID確定、受付成功後の割当て競合監査、例外時の自予約だけの解放を実装した。
- 予約解放に失敗した場合は他taskの割当てを変更せず、`DISPATCH_RESERVATION_RELEASE_FAILED`へ現在recordを残すようにした。
- `test/unit_conductor_dispatch_reservation.jl`を追加し、右優先、LIST除外、同時予約、正常ACK、現行BUSY失敗を独立に検査する構造を実装した。
- BUSY分類、DONE照合、task lifecycleは変更していない。
- `git diff --check`で検査できる範囲のwhitespace不整合はない。機能検証はPhase 4で行う。

### Phase 4: テストまたは検証を行う — 完了

#### 初回検証と強化C補正

- 初回の正常ACK経路は、`split`由来の`SubString` job IDを`mark_node_running!(..., job_id::String)`へ渡したため`MethodError`となり、5 assertionsが失敗した。
- wire応答、状態設計、Todo前提の問題ではなく、灯子が配送境界で具体的な`String`へ確定しなかった局所的な型ミスだった。
- ACK取得時に`String(fetch(dispatch_task))`へ直し、同じPhase 4を最初から再実行した。
- 失敗したtestset内でもPASS markerが先に表示される配置も灯子の試験記述ミスだったため、testset成功後だけ表示する位置へ同時に修正した。

#### 最終検証

- `julia --startup-file=no --threads=4 --project=. test/unit_conductor_dispatch_reservation.jl`を補正後2回実行し、いずれもexit `0`、`29 / 29 pass`、marker `STEP3_RESULT=PASS_ATOMIC_DISPATCH_RESERVATION`。
- 右優先予約、予約中LIST除外、逐次予約、4 threads上の二重予約競合で成功1件/失敗1件を確認した。
- 正常ACKはrecordが`busy/task-success/job-success`となり、queueは0だった。
- 現行BUSY例外は自予約だけを`down`へ解放し、taskをretry 1でqueueへ戻した。BUSY専用修正前なのでStep 3の期待どおりである。
- `test/regression_conductor_stale_idle.jl`: exit `0`、`26 / 26 pass`、artifact `/tmp/syncopade-step3-stale.niQJXB`。
- `test/reproduction_conductor_busy_drop.jl`: exit `0`、`39 / 39 pass`、artifact `/tmp/syncopade-step3-busy.BG7Fd7`。
- `test/unit_conductor_node_state.jl`: exit `0`、`55 / 55 pass`。
- `test/unit_conductor_queue.jl`: exit `0`、`17 / 17 pass`。
- `test/integration_conductor_wrapper_entrypoint.jl 192.168.100.30 9030 8.0`: exit `0`、marker `STEP3_RESULT=PASS_WRAPPER_ENTRYPOINT_REGRESSION`。
- wrapperは`NODES|`を返して継続起動し、SIGTERMで終了、SIGKILL fallbackなし、include-onlyはexit `0`、最終9030/tcp再bind成功だった。
- wrapper artifact: `/var/folders/__/7pnh5g_x5qb2r25n4tgyyhww0000gn/T/syncopade-wrapper-entrypoint-TPdxIJ`。
- `git diff --check`はerrorなし。
- repository log SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`のままで、先生の既存差分を変更していない。

### Step 3結論

nodeの右優先選択とtask ID付き予約が一つのlock区間になり、予約中nodeはLISTと後続選択から除外される。正常ACKは同じ予約へjob IDを保存し、ACK前失敗は他taskへ触れず自予約だけを解放することを確認した。

---

## Step 4: DONEをtask IDとjob IDで照合する — 完了

### 目的

遅延または重複した`DONE`が、別taskを実行中のnodeをidleへ戻さないようにする。

### 対象ファイル

- `syncopadeConductor.jl`
- `test/regression_conductor_done_identity.jl`（新規候補）
- このTodo

### 完了条件

- `DONE`のworker endpoint、task ID、job IDが現在割当てと一致する場合だけnodeを解放する。
- endpoint不明、task不一致、job不一致、重複DONEは現在割当てを変えない。
- 正常DONEと無視したDONEを異なるevent名で監査logへ記録する。
- 正常DONE後のnodeは次taskへ予約できる。

### 検証方法

1. task A終了後にtask Bを割り当て、遅延したtask AのDONEでtask Bが解放されないことを確認する。
2. task Bの正しいDONEだけがnodeをidleへ戻すことを確認する。
3. 同じDONEを2回送っても解放logとtask終端が1回だけであることを確認する。
4. 既存DONE/log試験を実行する。

### Phase 1: 実装方針をまとめる — 完了

- `handle_done_payload`がendpointだけで無条件idle化する処理を廃止し、node recordの現在割当てと受信task/job IDを同じ`node_states_lock`区間で照合する専用DONE遷移へ置き換える。
- 通常は現在recordが`NODE_BUSY`、task ID一致、job ID一致の場合だけ割当てを解放する。
- workerはACK送信後すぐ計算taskを開始するため、非常に短いjobではconductorがACKからjob IDを保存する前にDONE処理が先行し得る。現在recordが`NODE_RESERVED`、task ID一致、job ID未確定の場合は、DONEの非空job IDをその予約のjob IDとして受理して直接完了できる早期DONE経路を設ける。
- 早期DONE後にACK処理が戻った場合、Step 3の`mark_node_running!`は失敗するが、worker受付済みとして再投入せず`DISPATCH_ASSIGNMENT_CONFLICT`へ記録する既存方針を維持する。
- endpointのruntime recordなし、割当てなし、task不一致、job不一致、状態不一致、重複DONEはnode状態を変更せず`DONE_IGNORED`へ理由と現在recordを記録する。
- 正常DONEだけを既存`TASK_DONE`へ記録する。無視したDONEは`TASK_DONE`として数えず、conductor serverからworkerへの`OK|DONE_ACK`自体は返して再送loopを起こさない。
- `handle_done_payload`は正常適用を`true`、無視を`false`で返す内部契約にし、既存callerは戻り値を無視できる。
- networkなしの回帰試験で、task A正常完了後にtask Bを割り当て、遅延A、Bの誤job、未知endpoint、正常B、重複Bを順に与える。Bを解放できるのは正常Bだけとする。
- 同じ試験で早期DONEも与え、予約task一致なら完了でき、後続ACK相当のmarkが成立しないことを確認する。
- task lifecycle全体のterminal管理はStep 7へ残し、このStepはnode割当て解放とDONE監査だけを扱う。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### `apply_done_to_node!(node::NODES, task_id::String, job_id::String)::NamedTuple`

- 戻り値は`released::Bool`、`reason::Symbol`、`previous::NodeRuntimeState`を持つ。
- `node_states_lock`内でendpoint recordの存在、現在state、task ID、job IDを照合する。
- `NODE_BUSY`でtask/job IDが完全一致した場合、`NODE_IDLE`、空task/job、generation + 1へ置換し、`released=true, reason=:matched`を返す。
- `NODE_RESERVED`でtask ID一致、現在job ID空、受信job ID非空の場合は早期DONEとして同じ解放を行い、`released=true, reason=:early_done`を返す。
- recordなしは`:untracked_endpoint`、割当てなしは`:no_assignment`、task不一致は`:task_mismatch`、空または不一致jobは`:job_mismatch`、上記以外のstateは`:state_mismatch`とする。
- 不成立時はrecordを変更せず、`released=false`と判定時のprevious snapshotを返す。
- 解放成功時だけ既存`NODE_STATE_CHANGED`を記録する。queue、retry、network I/Oは変更しない。

#### `handle_done_payload(payload::String)::Bool`

- 既存10 fields以上の`DONE`形式を維持し、task ID、job ID、worker IPを具体的な`String`、portを`Int`へ変換する。
- 形式不足またはport不正は従来どおり例外とし、node stateとlogを変更しない。
- `apply_done_to_node!`成功時は既存fieldsで`TASK_DONE`を1件記録して`true`を返す。
- 不成立時は`DONE_IGNORED`を1件記録して`false`を返す。
- `DONE_IGNORED`は受信task/job ID、endpoint、現在stateを通常列に持ち、`error`へ`reason`、現在task/job ID、現在generation、worker error本文を記録する。
- conductor serverは戻り値にかかわらず、parseが成功したDONEへ既存`OK|DONE_ACK`を返す。

#### 回帰試験

- file: `test/regression_conductor_done_identity.jl`。
- task A正常DONEでAを解放した後、task Bを同nodeへ予約・running化する。
- 遅延task A DONE、task Bの誤job DONE、未登録endpoint DONEでtask B recordが完全一致のまま変わらないことを確認する。
- task B正常DONEだけがidle化し、同じDONEの再送は`:no_assignment`で無視されることを確認する。
- task Cはreserved/job未確定のまま同task ID・非空job IDのDONEを送り、早期DONEとしてidle化する。その後の`mark_node_running!`は`false`とする。
- logは`TASK_DONE=3`、`DONE_IGNORED=4`で、無視理由`task_mismatch`、`job_mismatch`、`untracked_endpoint`、`no_assignment`を各1件含む。
- malformed DONEが例外になり、状態を変えないことも確認する。
- 一時logを使い、終了時にwriter、node state、task queueをcleanupする。

### Phase 3: 実装する — 完了

- node recordの存在、state、task ID、job IDを一つのlock区間で照合する`apply_done_to_node!`を追加した。
- 通常のbusy完全一致と、reserved/task一致/job未確定に対する早期DONEを成功経路として実装した。
- `handle_done_payload`を具体的な`String` fieldsへ変換し、成功を`TASK_DONE`、不成立を理由付き`DONE_IGNORED`へ分け、Boolを返すよう変更した。
- 未登録endpoint、割当てなし、task不一致、job不一致、state不一致ではnode recordを変更しない。
- conductor serverの既存`OK|DONE_ACK`応答は変更していない。
- `test/regression_conductor_done_identity.jl`を追加し、正常A、遅延A、誤job B、未知endpoint、正常B、重複B、早期C、malformed payloadを固定順で検査する構造を実装した。
- task lifecycle、terminal通知、callback形式は変更していない。
- `git diff --check`で検査できる範囲のwhitespace不整合はない。機能検証はPhase 4で行う。

### Phase 4: テストまたは検証を行う — 完了

- `julia --startup-file=no --project=. test/regression_conductor_done_identity.jl`を2回連続実行し、いずれもexit `0`、`33 / 33 pass`、marker `STEP4_RESULT=PASS_DONE_IDENTITY`。
- task Aとtask Bの正常DONEだけが各割当てを解放した。
- task B実行中の遅延task A DONE、task Bの誤job DONE、未登録endpoint DONEはtask B recordを変更しなかった。
- task B正常DONE後の重複DONEは割当てなしとして無視された。
- task Cのreserved/job未確定状態へ同task ID・非空job IDのDONEを与え、早期DONEとしてidle化した。後続ACK相当の`mark_node_running!`は`false`となった。
- 一時logは`TASK_DONE=3`、`DONE_IGNORED=4`で、理由`task_mismatch`、`job_mismatch`、`untracked_endpoint`、`no_assignment`を各1件含んだ。
- malformed DONEは`ArgumentError`となり、node recordを変更しなかった。
- `test/unit_conductor_dispatch_reservation.jl`: exit `0`、`29 / 29 pass`。
- `test/regression_conductor_stale_idle.jl`: exit `0`、`26 / 26 pass`、artifact `/tmp/syncopade-step4-stale.JNJbF7`。
- `test/unit_conductor_node_state.jl`: exit `0`、`55 / 55 pass`。
- `git diff --check`はerrorなし。
- repository log SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`のままで、先生の既存差分を変更していない。

### Step 4結論

DONEはendpointだけでnodeをidle化せず、現在のtask/job割当てと対応する場合だけ解放する。古い・不一致・重複DONEは監査logへ分離され、ACK保存前の正しい早期DONEも失われないことを確認した。

---

## Step 5: worker受付応答を種類別に解析する — 完了

### 目的

`OK|STARTED|job_id`、`ERROR|BUSY`、protocol異常、通信失敗、受付応答timeoutを同じ一般例外へ潰さず、conductorが判断できる形に分ける。

### 対象ファイル

- `syncopadeClient.jl`
- `syncopadeConductor.jl`
- `test/unit_client_protocol.jl`
- `test/unit_controlled_worker_fixture.jl`
- このTodo

### 完了条件

- 正常受理はjob ID付き、BUSYは未受理確定、timeoutは受付成否不明として区別できる。
- malformed response、接続失敗、読取り失敗をBUSYと誤認しない。
- 既存の`syncopade_calc_request`成功時戻り値は`String jobId`のまま維持する。
- 直接workerへ投入する既存callerがBUSY以外で受ける例外契約を不用意に変更しない。

### 検証方法

1. 制御workerから正常受理、BUSY、不正応答を返し、分類結果を個別に確認する。
2. 応答保留によりtimeout分類を確認し、BUSYと区別する。
3. 正常受理時だけjob IDが得られることを確認する。
4. 既存client protocol testとserver BUSY拒否試験を実行する。

### Phase 1: 実装方針をまとめる — 完了

- worker受付応答の解析をsocket処理から分離し、正常受理とBUSYを異なるreply型、malformed responseを専用protocol例外として表す。
- `syncopade_calc_request`の成功戻り値は具体的な`String` job IDのまま維持し、BUSYでは`SyncopadeWorkerBusyError`、不正応答では`SyncopadeWorkerProtocolError`を送出する。
- socketは接続後の送信、読取り、解析の成功・失敗にかかわらず`finally`で閉じ、分類追加によるdescriptor残留を防ぐ。
- conductorの受付応答timeoutは専用`SyncopadeWorkerStartTimeoutError`へ変更する。通信接続・読取り例外は既存Julia例外を保ち、共通分類helperで`:transport_error`と判定する。
- 現在の`@async syncopade_calc_request`は内部例外を`TaskFailedException`で包むため、async task内で例外値を捕捉したresultを返し、conductor側catchが元のBUSY/protocol例外を直接分類できるようにする。
- conductorのcatchは分類結果を`DISPATCH_FAILED.status`へ記録するが、このStepでは全分類を従来どおり自予約解放、node down、failure retryへ流す。BUSYだけを待機へ変えるのはStep 6とする。
- reply型と例外型はこのStepでは内部契約とし、package exportは増やさない。公開結果protocolの型とexportはStep 9でまとめて扱う。
- `test/unit_client_protocol.jl`で純粋な応答解析を確認し、`test/unit_controlled_worker_fixture.jl`で実TCPの正常、BUSY、malformed、接続拒否を個別に確認する。
- timeoutは長い実待機をせず、専用例外値の分類を単体確認する。実際の保留応答と再配送防止はStep 8で検証する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### worker start reply型

- `abstract type WorkerStartReply end`を内部基底型とする。
- `WorkerStartAccepted(job_id::String) <: WorkerStartReply`は非空job IDを持つ。
- `WorkerStartBusy(raw_response::String) <: WorkerStartReply`は正確な受信行を持つ。

#### worker start例外型

- `SyncopadeWorkerBusyError(raw_response::String) <: Exception`。
- `SyncopadeWorkerProtocolError(raw_response::String) <: Exception`。
- `SyncopadeWorkerStartTimeoutError(timeout_seconds::Float64) <: Exception`。
- BUSYの`showerror`は既存test/logとの照合を保つため`Unexpected response from server: ERROR|BUSY`を含める。
- protocol例外も`Unexpected response from server: <raw>`を含める。
- timeout例外は秒数と、worker start ACKの受付成否が不明であることを示す。

#### `parse_worker_start_response(response::AbstractString)::WorkerStartReply`

- 改行を除いた応答が厳密に`OK|STARTED|<nonempty_job_id>`なら`WorkerStartAccepted`を返す。
- 厳密に`ERROR|BUSY`なら`WorkerStartBusy`を返す。
- field不足、余分field、空job ID、未知statusは`SyncopadeWorkerProtocolError`とする。
- network、file、global stateを変更しない純粋な解析関数とする。

#### `syncopade_calc_request(pList::SyncopadeClient)::String`

- request wire形式は変更しない。
- `WorkerStartAccepted`なら具体的な`String` job IDを返す。
- `WorkerStartBusy`なら同じraw responseを持つ`SyncopadeWorkerBusyError`を送出する。
- protocol例外とtransport例外は型を保って上位へ送出する。
- 接続に成功したsocketは`finally`で必ず閉じる。

#### `classify_worker_start_error(error_value)::Symbol`

- `SyncopadeWorkerBusyError`は`:busy`。
- `SyncopadeWorkerProtocolError`は`:protocol_error`。
- `SyncopadeWorkerStartTimeoutError`は`:outcome_unknown`。
- `Base.IOError`、`EOFError`、`SystemError`は`:transport_error`。
- その他は`:unexpected_error`。
- 分類だけを返し、例外送出、log、state変更は行わない。

#### conductor dispatch内のasync結果

- async taskは`(job_id=<String>, error=nothing)`または`(job_id="", error=<original exception>)`を返す。
- timedwait期限到達時は`SyncopadeWorkerStartTimeoutError(DEFAULT_DISPATCH_TIMEOUT)`を送出する。
- task完了時はresultをfetchし、`error !== nothing`なら元例外を再送出する。
- catchは`classify_worker_start_error`の結果を`DISPATCH_FAILED.status`へ記録する。
- state、queue、retryの分岐はこのStepでは既存経路を維持する。

#### 試験

- `test/unit_client_protocol.jl`でaccepted、BUSY、空job ID、余分field、未知応答と全分類記号を確認する。
- `test/unit_controlled_worker_fixture.jl`でBUSY例外型、malformed例外型、正常job IDの具体型`String`、閉じたloopback portへの接続例外分類を確認する。
- controlled worker履歴はSTATUS 1件、job 3件（BUSY、malformed、accepted）とし、request/response ID対応を維持する。
- cleanup後にworker portを再bindできることを確認する。

### Phase 3: 実装する — 完了

- worker start reply 2型、BUSY/protocol/timeout例外3型、`showerror`、例外分類helperを`syncopadeClient.jl`へ追加した。
- 応答解析を`parse_worker_start_response`へ分離し、正常job IDを具体的な`String`、BUSYを専用reply、不正形式を専用例外として実装した。
- `syncopade_calc_request`を成功時`String`契約へ固定し、接続後socketを`finally`で閉じるよう変更した。
- conductorのasync requestは元例外をNamedTuple内で保持して返し、`TaskFailedException`へ包まれたまま分類しない構造へ変更した。
- start ACK timeoutを専用例外へ変更し、`DISPATCH_FAILED.status`へ分類記号を追加した。state、retry、requeue分岐は変更していない。
- `test/unit_client_protocol.jl`へ純粋解析と分類試験、`test/unit_controlled_worker_fixture.jl`へ実TCPのBUSY、malformed、accepted、transport error試験を追加した。
- 最初の一括patchは末尾log行の現行文脈指定が一致せず全体未適用となった。灯子のpatch位置指定ミスで、仕様・実装差分は入っていなかったため、強化Cの局所補正としてclient、conductor、testへ分割して適用した。
- `git diff --check`はerrorなし。機能検証はPhase 4で行う。

### Phase 4: テストまたは検証を行う — 完了

#### 初回検証と強化C補正

- `test/unit_client_protocol.jl`は初回から`23 / 23 pass`。
- controlled worker初回はfixtureが`ERROR|BUSY`と正常ACK以外を禁止していたため、malformed応答を返す前にfixture自身が`ArgumentError`となり、`10 pass / 1 error`で停止した。
- client分類やTodo前提の問題ではなく、灯子が新しいmalformed試験に必要なfixture応答を許可し忘れた局所ミスだった。
- fixtureの許可応答へ試験専用`ERROR|UNEXPECTED`だけを追加し、任意文字列は許可せず、同じPhase 4を最初から再実行した。

#### 最終検証

- `test/unit_client_protocol.jl`: exit `0`、`23 / 23 pass`。accepted/BUSY、malformed 3種、BUSY/protocol/timeout/transport/unexpected分類を確認した。
- `test/unit_controlled_worker_fixture.jl`を補正後2回実行し、いずれもexit `0`、`23 / 23 pass`。
- 実TCPでBUSYは`SyncopadeWorkerBusyError/:busy`、malformedは`SyncopadeWorkerProtocolError/:protocol_error`、正常ACKは具体的な`String` job IDとなった。
- 閉じたloopback portへの接続はtransport例外となり、`:transport_error`へ分類された。controlled worker終了後は同portを再bindできた。
- `test/reproduction_conductor_busy_drop.jl`: exit `0`、`39 / 39 pass`、artifact `/tmp/syncopade-step5-busy.cwbRkS`、CSV SHA-1 `ec94c0335c71d35461f62d24e0483d5239ad632b`。
- BUSY 4回は全て`DISPATCH_FAILED.status=busy`、例外本文`Unexpected response from server: ERROR|BUSY`として記録された。
- Step 6前なのでBUSYは従来どおりretry `0..3`を消費し、1回dropした。分類以外の挙動を変えていない証拠である。
- `test/unit_conductor_dispatch_reservation.jl`: exit `0`、`29 / 29 pass`。
- `test/regression_conductor_done_identity.jl`: exit `0`、`33 / 33 pass`。
- `test/regression_conductor_stale_idle.jl`: exit `0`、`26 / 26 pass`、artifact `/tmp/syncopade-step5-stale.MkXF4x`。
- `git diff --check`はerrorなし。
- repository log SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`のままで、先生の既存差分を変更していない。

### Step 5結論

workerの正常受理、BUSY未受理、protocol異常、transport失敗、受付成否不明timeoutを別々に識別できる。conductor logへ分類を残しつつ、このStepでは意図どおりretry判断をまだ変更していない。

---

## Step 6: BUSYでtaskを失わず、空いた後に1回だけ配送する — 完了

### 目的

workerのBUSY拒否を故障再試行から外し、taskとnodeを正しい状態へ戻して次の空き確認を待つ。

### 対象ファイル

- `syncopadeConductor.jl`
- `test/reproduction_conductor_busy_drop.jl`（修正後回帰試験へ変更・改名候補）
- `test/unit_conductor_dispatch_reservation.jl`
- `test/fixtures/conductor_controlled_worker.jl`
- このTodo

### 完了条件

- BUSY時にnodeを`down`へ変更しない。
- BUSY時にtaskの通常配送失敗回数を増やさない。
- BUSY taskをqueueへ1回だけ戻し、同一dispatch cycle内の即時再送を止める。
- 後続STATUSでworkerがidleになった後、同じtask IDを1回だけ正常配送する。
- 接続失敗やprotocol異常の既存retryはBUSY経路と分離して維持する。

### 検証方法

1. 制御workerに複数回BUSYを返させ、retry countが変わらず`TASK_DROPPED`がないことを確認する。
2. 各cycleのworker requestが最大1回であることを確認する。
3. workerをidleへ変更後、同じtask IDが1回だけ`OK|STARTED`へ到達することを確認する。
4. nodeがBUSYで`down`にならず、最終DONE後にidleへ戻ることを確認する。

### Phase 1: 実装方針をまとめる — 完了

- `dispatch_to_worker`のBoolを、少なくともaccepted、BUSY未受理、通常失敗を区別する内部`DispatchOutcome`へ変更する。Step 8で受付成否不明を追加できる形にする。
- BUSY時は現在の`NODE_RESERVED/task_id/job_id空`を同じlock区間で`NODE_BUSY/task_id空/job_id空`へ置換する専用遷移を追加する。Step 1の通常解放契約は変更しない。
- BUSY専用遷移が成立した場合、nodeはdownでなく「外部で使用中と観測された未割当てbusy」となる。後続STATUSは割当てなしなのでStep 2の世代照合を通ってidleへ戻せる。
- BUSY専用遷移が不成立でも他taskのrecordを変更しない。現在recordを`BUSY_RESERVATION_RELEASE_FAILED`へ記録する。
- BUSYは`DISPATCH_FAILED`ではなく`DISPATCH_BUSY`へ記録し、例外本文`ERROR|BUSY`と分類`busy`を残す。通常の通信・protocol失敗は従来の`DISPATCH_FAILED`を維持する。
- `dispatch_queued_tasks`はBUSY outcomeで元の`ConductorTask`を変更せずqueueへ1回戻し、`TASK_REQUEUED_BUSY`を記録してそのcycleをreturnする。`retry_count`は増やさない。
- accepted outcomeは従来どおり次のqueued taskへ進み、通常失敗outcomeだけが`requeue_with_retry!`を呼ぶ。
- 修正前BUSY試験を`test/regression_conductor_busy_wait.jl`へ改名し、BUSY 3回の各cycleでqueue 1件/retry 0/node busy/no dropを確認後、idle観測と正常ACK 1回で同taskを受理する期待へ反転する。
- 正常ACK後は同task/jobのDONEを与え、nodeがidleへ戻るところまで確認する。worker requestはBUSY 3件＋正常受付1件の計4件で、正常受付は1件だけとする。
- Step 6では待機期限をまだ導入しない。BUSY taskの期限付き終端はStep 8、task lifecycleはStep 7へ残す。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### `DispatchOutcome`

- internal enumとして`DISPATCH_ACCEPTED`、`DISPATCH_BUSY_REJECTED`、`DISPATCH_FAILED`、後続Step用`DISPATCH_OUTCOME_UNKNOWN`を定義する。
- `dispatch_to_worker`は必ずこのいずれかを返し、Boolへ暗黙変換しない。

#### `mark_node_busy_after_rejection!(node::NODES, task_id::String)::Bool`

- 空でないtask IDを要求する。
- `node_states_lock`内で現在recordが`NODE_RESERVED`、task ID一致、job ID空の場合だけ、`NODE_BUSY`、空task/job、generation + 1へ置換する。
- 成功時は`NODE_STATE_CHANGED`の`reserved -> busy`を記録して`true`を返す。
- 条件不一致ではrecordを変えず`false`を返す。
- queue、retry、network I/Oは変更しない。

#### `dispatch_to_worker`のBUSY分岐

- 正常ACKは`DISPATCH_ACCEPTED`を返す。
- catchした例外分類が`:busy`なら`mark_node_busy_after_rejection!`を呼ぶ。
- 遷移不成立時だけ`BUSY_RESERVATION_RELEASE_FAILED`へ現在state、task/job ID、generationを記録する。
- BUSYは`DISPATCH_BUSY`を1件記録し、status `busy`、raw例外本文を残して`DISPATCH_BUSY_REJECTED`を返す。
- BUSY経路では`DISPATCH_FAILED`、node down、failure retryを行わない。
- BUSY以外の例外は自予約をdownへ解放し、既存`DISPATCH_FAILED`を記録して`DISPATCH_FAILED` outcomeを返す。
- timeout分類はStep 6ではBUSY以外の既存失敗経路に残し、Step 8で`DISPATCH_OUTCOME_UNKNOWN`へ接続する。

#### `dispatch_queued_tasks`のoutcome処理

- `DISPATCH_ACCEPTED`はqueue loopを継続する。
- `DISPATCH_BUSY_REJECTED`は元taskをそのまま`enqueue_task!`し、`TASK_REQUEUED_BUSY`を1件記録してreturnする。
- `DISPATCH_FAILED`だけが`requeue_with_retry!`を呼ぶ。
- 未接続の`DISPATCH_OUTCOME_UNKNOWN`を受けた場合はsilent fallthroughせず`ArgumentError`とする。Step 8で正式処理へ置き換える。

#### 修正後回帰試験

- fileを`test/reproduction_conductor_busy_drop.jl`から`test/regression_conductor_busy_wait.jl`へ改名する。
- 固定task IDとretry `0`で開始し、3 cyclesだけ制御workerへ`ERROR|BUSY`を返す。
- 各cycle後はnode `busy`かつ割当てなし、queue 1件、同じtask ID、retry `0`とする。
- 4 cycle目の前にnodeをidleへ戻し、`OK|STARTED|controlled-job-after-busy`を返す。
- 正常受付後はqueue 0、node `busy/task_id/job_id`とし、同task/jobのDONE後はidleとする。
- worker履歴はjob request/response各4件、BUSY 3件、正常ACK 1件、正常job ID 1種類とする。
- logは`DISPATCH_BUSY=3`、`TASK_REQUEUED_BUSY=3`、`DISPATCH_OK=1`、`TASK_DONE=1`、`DISPATCH_FAILED=0`、`TASK_REQUEUED=0`、`TASK_DROPPED=0`とする。
- 一時log、bounded worker cleanup、queue/node state cleanup、repository log不変を維持する。

### Phase 3: 実装する — 完了

- `DispatchOutcome` enumと、BUSY拒否時に自予約を割当てなしbusyへ移す`mark_node_busy_after_rejection!`を追加した。
- `dispatch_to_worker`をtyped outcomeへ変更し、BUSYだけを`DISPATCH_BUSY`と`DISPATCH_BUSY_REJECTED`へ分離した。
- BUSY専用状態遷移が失敗した場合は他割当てを変更せず、現在recordを`BUSY_RESERVATION_RELEASE_FAILED`へ記録するようにした。
- `dispatch_queued_tasks`はBUSY taskをretry増加なしで1回queueへ戻し、`TASK_REQUEUED_BUSY`を記録して同cycleを終了するよう変更した。
- 正常ACKと通常失敗の既存分岐はそれぞれ`DISPATCH_ACCEPTED`、`DISPATCH_FAILED`へ接続した。timeout unknownの正式処理はStep 8へ残した。
- `test/reproduction_conductor_busy_drop.jl`を削除し、正方向の`test/regression_conductor_busy_wait.jl`を追加した。
- Step 3の予約単体試験も、BUSY後にdown/retry 1でなくbusy/割当てなし/retry 0を期待するよう追従させた。
- task lifecycle、待機期限、terminal通知は変更していない。
- `git diff --check`で検査できる範囲のwhitespace不整合はない。機能検証はPhase 4で行う。

### Phase 4: テストまたは検証を行う — 完了

#### 初回検証と強化C補正

- `test/regression_conductor_busy_wait.jl`は初回からexit `0`、`48 / 48 pass`となった。
- 周辺回帰を並列実行した際、既存の`test/unit_conductor_queue.jl`と`test/unit_conductor_node_state.jl`がrepository logを一時pathへ切り替えないため、灯子の試験手順ミスで`logs/conductor_events.csv`へ試験由来5行が追加された。
- 追加時刻と内容が今回の試験出力に一致する5行だけを除去し、先生の既存差分4行は維持した。補正後のrepository log SHA-1が事前値と一致することを確認した。
- これは製品コードの前提変更ではない。該当2試験のlog隔離改定はこのStepへ混ぜず、Step 11の全回帰実行時に対象と検証範囲を見直す。

#### 最終検証

- `test/regression_conductor_busy_wait.jl`を合計3回実行し、すべてexit `0`、`48 / 48 pass`、`STEP6_RESULT=PASS_BUSY_WAIT_AND_ACCEPT`となった。
- 3回のBUSY後もqueueは同じtask ID 1件、retry `0`を維持した。4回目だけ`controlled-job-after-busy`を受理し、同task/jobのDONE後にnodeがidleへ戻った。
- 永続artifactは`/tmp/syncopade-step6-final.vOQbWX/conductor_events.csv`、SHA-1は`2dc591989be1f3aa611925d440c13b4b65d7fb72`。
- artifact logは`DISPATCH_START=4`、`DISPATCH_BUSY=3`、`TASK_REQUEUED_BUSY=3`、`DISPATCH_OK=1`、`TASK_DONE=1`、`DISPATCH_FAILED=0`、`TASK_REQUEUED=0`、`TASK_DROPPED=0`を満たした。
- `test/unit_conductor_dispatch_reservation.jl`: exit `0`、`29 / 29 pass`。
- `test/unit_client_protocol.jl`: exit `0`、`23 / 23 pass`。
- `test/unit_controlled_worker_fixture.jl`: exit `0`、`23 / 23 pass`。
- `test/regression_conductor_done_identity.jl`: exit `0`、`33 / 33 pass`。
- `test/regression_conductor_stale_idle.jl`: exit `0`、`26 / 26 pass`、artifact `/tmp/syncopade-step6-stale.ZkZbKR`。
- `test/unit_conductor_node_state.jl`: exit `0`、`55 / 55 pass`。
- `test/unit_conductor_queue.jl`: exit `0`、`17 / 17 pass`。
- `git diff --check`はerrorなし。
- repository log SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`に復帰し、先生の既存差分4行だけを保持している。

### Step 6結論

workerがBUSYを返してもnodeをdownへ落とさず、taskはretryを消費せずqueueに残る。workerがidleになった後の正常ACKは1回だけrunning割当てとなり、対応するDONEで解放される。

---

## Step 7: conductor taskの寿命と状態照会を実装する — 完了

### 目的

受付済みtaskをqueueから消えた後もtask IDで追跡し、callbackに失敗しても親が状態を照会できるようにする。

### 対象ファイル

- `syncopadeConductor.jl`
- `syncopadeClient.jl`
- `src/Syncopade.jl`
- `test/unit_conductor_task_lifecycle.jl`（新規候補）
- `test/unit_client_protocol.jl`
- `test/reproduction_conductor_silent_drop.jl`（lifecycle前提へのfixture追従のみ）
- このTodo

### 完了条件

- task IDごとに`queued`、`reserved`、`running`、`dispatch_unknown`、`terminal`を区別して保持する。
- 許可された遷移だけが成功し、terminalから非terminalへ戻らない。
- conductorにtask ID指定の読取り専用状態照会commandを追加する。
- 公開client APIから状態、job ID、終端種別、理由を取得できる。
- 未知task IDは既知taskの失敗と区別できる。

### 検証方法

1. networkなしの単体試験で許可遷移と禁止遷移を全て確認する。
2. conductor protocol試験で各状態と未知task IDの応答を確認する。
3. terminal状態を重ねて更新しても最初の終端内容が保持されることを確認する。
4. 状態照会がqueue順序、node状態、callbackを変更しないことを確認する。

### Phase 1: 実装方針をまとめる — 完了

- conductor内にnode状態とは別のtask lifecycle registryを置き、task IDからimmutableな現在状態を引けるようにする。保存はprocess memory内だけとし、再起動永続化は追加しない。
- lifecycle stateは`queued`、`reserved`、`running`、`dispatch_unknown`、`terminal`の5種に固定する。worker job ID、terminal種別、理由も同じrecordへ保持する。
- queue投入をlifecycleの入口にする。新規taskは`queued`として登録し、BUSYまたは通常retryの再投入は`reserved -> queued`、idle nodeなしの再投入は`queued -> queued`として扱う。
- node予約成功時にtaskを`reserved`、正常start ACK時にjob ID付き`running`へ進める。retry上限超過と受理済みDONEは`terminal`へ進める。
- `dispatch_unknown`への実際の遷移はStep 8で接続するが、状態表と許可遷移はこのStepで定義し、後続Stepがterminalを巻き戻さず接続できる形にする。
- terminal recordは最初の1件を正本とし、重複DONEや後着ACKを含む全更新を拒否する。node側の世代管理と同様、task側もlock下で比較と更新を完結させる。
- conductor commandへ`TASK_STATUS|task_id`を追加する。既知taskはstate、job ID、terminal種別、理由を返し、未知taskは正常な別応答として返す。
- client側には状態応答の具体型、未知task応答の具体型、純粋parser、TCP query関数を追加する。未知taskを通信・protocol errorとして潰さない。
- 状態照会はregistryのsnapshotを読むだけとし、queue、node state、callback、logを変更しない。
- 単体試験は全許可遷移、禁止遷移、terminal first-write-wins、照会前後のqueue/node不変、全wire応答と未知taskを確認する。既存のdispatch/DONE回帰も再実行する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### `TaskRuntimeState`

- fieldsは`state::Symbol`、`generation::UInt64`、`job_id::String`、`terminal_kind::String`、`reason::String`とする。
- 非terminalでは`terminal_kind`と`reason`を空にする。`running`だけは非空job IDを必須とし、`queued`、`reserved`、`dispatch_unknown`は空job IDとする。
- terminalでは非空`terminal_kind`を必須とし、job IDはworker受理済みなら保持、未受理なら空を許す。

#### task lifecycle registry

- `task_runtime_states::Dict{String,TaskRuntimeState}`を`task_runtime_states_lock`で保護する。
- `get_task_runtime_state(task_id)::Union{Nothing,TaskRuntimeState}`はlock下のsnapshotを返し、未知IDは`nothing`とする。空task IDは`ArgumentError`。
- `transition_task_state!(task_id, next_state; job_id="", terminal_kind="", reason="")::Bool`はvalidationと比較更新を同じlock内で行う。
- 未登録からは`queued`だけを許可する。許可遷移は`queued -> reserved|terminal`、`reserved -> queued|running|dispatch_unknown|terminal`、`running -> terminal`、`dispatch_unknown -> running|terminal`とする。
- `queued -> queued`だけはqueueへ戻す操作のidempotent successとして許可し、recordとgenerationを変えない。
- terminalからの全遷移と上記以外は`false`を返し、既存recordを変更しない。不正state、空ID、stateとfieldの不整合は`ArgumentError`。
- terminal化でjob IDを省略した場合は現在recordのjob IDを引き継ぐ。最初のterminal化だけがrecordとgenerationを更新し、2回目以降はkindやreasonが異なっても拒否する。

#### lifecycle wrapperと既存経路への接続

- `mark_task_queued!`、`mark_task_reserved!`、`mark_task_running!`、`mark_task_dispatch_unknown!`、`mark_task_terminal!`は上のprimitiveへ委譲する。
- `enqueue_task!`はqueueへpushする前に`mark_task_queued!`を行い、禁止遷移なら例外として重複配送を止める。
- node予約成功後に`mark_task_reserved!`、正常start ACK後に`mark_task_running!`を呼ぶ。task遷移が競合した場合は他taskの状態を上書きせず、監査eventを残す。
- retry上限超過は`terminal_kind=MAX_RETRY_EXCEEDED`、`reason=max_retry_exceeded`とする。
- 一致DONEはstatus `OK`なら`WORKER_DONE_OK`、それ以外なら`WORKER_DONE_ERROR`としてterminal化し、DONEのerror fieldをreason、job IDをterminal recordへ保存する。
- 不一致または重複DONEは従来どおり`DONE_IGNORED`とし、task lifecycleも変更しない。
- `mark_task_dispatch_unknown!`はこのStepで単体検証可能にするが、dispatch timeout経路への接続はStep 8まで行わない。

#### conductor状態照会protocol

- request payloadは`TASK_STATUS|task_id`。
- 既知応答は`TASK_STATUS|KNOWN|task_id|state|job_id|terminal_kind|reason`。reason内の`|`は末尾field列として保持し、client parserがjoinして復元する。
- 未知応答は`TASK_STATUS|UNKNOWN|task_id`。未知はserver errorにしない。
- command field数不正または空task IDは従来のserver error処理へ流す。
- `task_status_response_payload(task_id)::String`はregistry snapshotだけからpayloadを作り、logや他stateを変更しない。

#### client公開API

- abstract `ConductorTaskStatus`と、既知用`KnownConductorTaskStatus(task_id, state, job_id, terminal_kind, reason)`、未知用`UnknownConductorTaskStatus(task_id)`を定義する。
- `parse_conductor_task_status_response(payload)::ConductorTaskStatus`は上記2形式だけを受理し、未知state、field不足、空task ID、未知tagは`SyncopadeWorkerProtocolError`ではなくconductor応答用`ArgumentError`として拒否する。
- `query_conductor_task_status(conductor_ip, task_id; conductor_port=9000)::ConductorTaskStatus`はchecksum付きrequestを1件送信し、checksum検証後にparser結果を返す。socketは成功・失敗とも`finally`で閉じる。
- positional port overloadも既存query APIと同じ形で提供する。

#### 試験

- 新規`test/unit_conductor_task_lifecycle.jl`で許可遷移、禁止遷移、generation、field validation、terminal first-write-winsをnetworkなしで確認する。
- 同試験で状態照会の前後にtask queue、node runtime state、repository外callback受信数が変わらないことを確認する。
- `test/unit_client_protocol.jl`で全5状態、terminalのdelimiter付きreason、未知task、malformed応答を確認する。
- 既存のBUSY待機、予約、DONE identity回帰を再実行する。

### Phase 3: 実装する — 完了

- `TaskRuntimeState`、5状態定数、task registry、専用lockをconductorへ追加した。
- field validation、許可遷移表、比較更新primitive、状態別wrapper、snapshot取得を実装した。
- `enqueue_task!`を新規登録と再queueの共通入口にし、node予約、正常ACK、retry上限超過、一致DONEをtask lifecycleへ接続した。
- terminalは最初の更新だけを保存し、retry上限を`MAX_RETRY_EXCEEDED`、DONEを`WORKER_DONE_OK/ERROR`として記録するようにした。
- node割当てとtask lifecycleの片側だけが競合した場合は`TASK_LIFECYCLE_CONFLICT`を記録し、他taskやterminal recordを上書きしない。
- conductorへ`TASK_STATUS|task_id` commandとread-only payload生成を追加した。
- clientへ既知・未知の状態応答型、純粋parser、checksum検証付きTCP query、positional port overloadを追加した。
- `test/unit_conductor_task_lifecycle.jl`を新設し、遷移表、retry terminal、DONE terminal、first-write-wins、照会副作用を検証する構成にした。
- `test/unit_client_protocol.jl`へ全状態、未知、malformed、delimiter付きreason、実TCP queryを追加した。
- client query追加時の最初のpatchは周辺空行の指定が現行文脈と一致せず未適用だった。灯子のpatch位置指定ミスで実装差分は入っていなかったため、強化Cの局所補正として一致する関数境界へ適用した。
- `syncopadeConductor.jl`のinclude smokeはexit `0`、`STEP7_INCLUDE_OK`。`git diff --check`もerrorなし。機能検証はPhase 4で行う。

### Phase 4: テストまたは検証を行う — 完了

#### 初回検証と強化C補正

- 新規lifecycle試験は初回からexit `0`、`120 / 120 pass`、client protocolも初回からexit `0`、`63 / 63 pass`となった。
- 差分監査で、関数実装はあるが`src/Syncopade.jl`のexport一覧に新しい状態型、parser、queryがないことを検出した。既存の「公開client API」完了条件を満たすための局所的な実装漏れとして5 symbolをexportし、対象ファイル欄へ同fileを追記した。
- lifecycle試験へ全5状態の遷移行列25組を追加し、試験artifact pathを外部指定できるようにした後、Phase 4を最初から再実行した。
- `test/reproduction_conductor_silent_drop.jl`は初回にexit `1`、`0 pass / 1 error`となった。原因は製品経路でなく、同試験だけが未登録taskへ`requeue_with_retry!`を直接呼ぶfixtureだったため、retry terminalへの遷移が拒否されたことだった。
- 同fixtureへ実配送と同じ`queued -> reserved`準備とregistry cleanupを追加した。callbackなしでdropする再現条件や期待結果は変更せず、Step 10の通知改定も先取りしていない。

#### 最終検証

- `test/unit_conductor_task_lifecycle.jl`: exit `0`、`145 / 145 pass`、`STEP7_RESULT=PASS_TASK_LIFECYCLE`。
- 永続artifactは`/tmp/syncopade-step7-final.SBa5Q0/conductor_events.csv`、SHA-1は`9c15acfd139c46b4f4f50686fdcfa4f9902bfe6d`。
- 25組の遷移行列、全許可経路、禁止経路、generation、field validation、terminal first-write-wins、retry terminal、DONE terminalを確認した。
- status payload生成前後でqueue、node、task snapshotが一致し、loopback callback listenerへの接続がないことを確認した。
- `test/unit_client_protocol.jl`: exit `0`、`63 / 63 pass`。5状態、未知task、malformed 7種、reason内`|`復元、checksum付き実TCP queryを確認した。
- package loadとexport smokeはexit `0`、`STEP7_PUBLIC_API=PASS`。
- `test/regression_conductor_busy_wait.jl`: exit `0`、`48 / 48 pass`。
- `test/unit_conductor_dispatch_reservation.jl`: exit `0`、`29 / 29 pass`。
- `test/regression_conductor_done_identity.jl`: exit `0`、`33 / 33 pass`。
- `test/regression_conductor_stale_idle.jl`: exit `0`、`26 / 26 pass`、artifact `/tmp/syncopade-step7-stale-final.ZvLTPR`。
- `test/reproduction_conductor_silent_drop.jl`: fixture補正後exit `0`、`11 / 11 pass`、artifact `/tmp/syncopade-step7-silent-final.bAH2HI`。callbackなしという修正前現象は維持された。
- `test/unit_conductor_queue.jl`: repository外logを指定してexit `0`、`17 / 17 pass`。
- `git diff --check`はerrorなし。
- repository log SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`のままで、先生の既存差分4行を変更していない。

### Step 7結論

conductorはtaskをqueueから消した後もprocess存続中はtask ID単位で追跡し、正常実行、retry打切り、未知taskを区別して照会できる。terminal recordは後着更新で巻き戻らない。dispatch timeoutを`dispatch_unknown`へ接続する処理は予定どおりStep 8へ残した。

---

## Step 8: worker受付期限と受付成否不明を別々に終端する — 完了

### 目的

BUSYまたはidle nodeなしでworker受付前のtaskを無期限に待たせず、同時に受付応答timeout後の危険な再配送を防ぐ。worker受付後の計算実行時間には制限を加えない。

### 対象ファイル

- `syncopadeConductor.jl`
- `syncopadeClient.jl`
- `test/regression_conductor_queue_deadline.jl`（新規候補）
- `test/regression_conductor_dispatch_timeout.jl`（新規候補）
- `test/fixtures/conductor_controlled_worker.jl`
- `test/unit_conductor_task_lifecycle.jl`（遅延BUSYの許可遷移追従）
- このTodo

### 完了条件

- task受付時に単調時計を基準としたworker受付待機の開始時刻と期限を保存する。
- 既定期限は`14400 s`で、conductor環境変数と投入ごとのclient API指定により上書きできる。
- BUSYまたはidle nodeなしでも期限前はtaskを保持する。
- `OK|STARTED|job_id`受信後は受付期限判定を終了し、長時間のworker計算を期限切れにしない。
- worker未受理が確定したまま期限到達したtaskは`QUEUE_TIMEOUT`でterminalになる。
- 受付応答timeout後は`dispatch_unknown`となり、別nodeを含め自動再配送しない。
- `dispatch_unknown`の期限到達は`DISPATCH_OUTCOME_UNKNOWN`となり、未実行とは記録しない。
- wall clock変更が待機時間計算を巻き戻さない。

### 検証方法

1. 注入した短い期限で、worker受付前の期限前保持と期限後の`QUEUE_TIMEOUT`を確認する。
2. workerが要求を受信して応答を保留するケースで、timeout後のrequest総数が1件のままであることを確認する。
3. 遅延受付応答または対応DONEが期限前に来た場合、正しいrunning/terminalへ遷移することを確認する。
4. 期限まで不明な場合だけ`DISPATCH_OUTCOME_UNKNOWN`になることを確認する。
5. worker受付後に注入時計を受付期限より先へ進めても、running taskが期限切れにならないことを確認する。

### Phase 1: 実装方針をまとめる — 完了

- worker受付待機期限と1回のdispatch ACK待ちtimeoutを別の時計として扱う。前者はtaskをconductorが最初にqueue登録した時点から始まり、後者はworkerへの各requestだけを監視する。
- 受付待機期限はwall clockでなく`time_ns()`由来の単調時計で保存する。既定値は`14400 s`とし、環境変数`SYNCOPADE_QUEUE_ACCEPTANCE_TIMEOUT_SECONDS`とSUBMITごとの値で上書き可能にする。
- taskの最初の`queued`登録時に開始時刻・絶対deadlineを保存し、BUSY、idle nodeなし、通常retryでqueueへ戻っても更新しない。
- deadline sweepはqueue全体を走査し、LIFO末尾以外の期限切れも除去する。worker requestをまだ送っていない`queued` taskは`QUEUE_TIMEOUT`でterminalにする。
- worker request後にACK timeoutへ達したtaskはnode予約を解放せず`dispatch_unknown`へ移し、queueへ戻さない。配送loopもそのcycleを終了し、同一・別nodeへの即時再配送を行わない。
- timeoutしたrequest task自体は捨てず、bounded watcherが後着結果を照合する。期限前の正常ACKは同じtask/nodeをrunningへ進め、期限前の対応DONEは既存early-DONE経路でterminalにする。
- timeout後に明示的な遅延BUSYが届いた場合だけ「未受理」が確定するため、`dispatch_unknown -> queued`を許可して元taskを再待機させる。これはtimeout時点での無条件再配送ではなく、明示的な非受理確認後の安全な再開とする。
- timeout後のprotocol/transport失敗は受理有無を確定できないため`dispatch_unknown`のまま保持する。deadline到達時だけ`DISPATCH_OUTCOME_UNKNOWN`でterminalにする。
- `dispatch_unknown` terminal時は対応する未確定node予約を`down`へ解放する。以後はnode STATUSでbusy/idleを再観測するまで配送対象にせず、task自体は再配送しない。
- 正常ACK後の`running` taskは受付deadline sweepの対象外にし、50分以上を含むworker実行時間へ新しいtimeoutを掛けない。
- client SUBMITはtimeout指定をfunction引数へ混ぜず、command直後の予約fieldとして送る。指定なしの旧SUBMIT wireはそのまま受理する。
- queue期限、ACK保留、後着ACK、早期DONE、request総数1件、running非期限切れをそれぞれ制御試験に分ける。実時間待機は短い試験値だけにし、4時間既定値は純粋関数と保存値で確認する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### timeout値とSUBMIT wire

- `DEFAULT_QUEUE_ACCEPTANCE_TIMEOUT_SECONDS = 14400.0`。
- `normalize_acceptance_timeout_seconds(value)::Float64`は`Real`を有限・正値の`Float64`へ変換し、0、負値、NaN、Infは`ArgumentError`とする。
- `default_queue_acceptance_timeout_seconds()::Float64`は`SYNCOPADE_QUEUE_ACCEPTANCE_TIMEOUT_SECONDS`があればparse・validationし、なければ既定値を返す。不正環境値はsilent fallbackしない。
- per-submit fieldは`ACCEPTANCE_TIMEOUT_SECONDS=<seconds>`とし、存在する場合だけ`SUBMIT`直後へ置く。旧形式`SUBMIT|coordinator_ip|...`との曖昧性を生じさせない。
- `submit_conductor_task`と`submit_conductor_task_and_wait`へ`acceptance_timeout_seconds::Union{Nothing,Real}=nothing`を追加し、指定時だけfieldを送る。
- `parse_submit_task`は予約fieldを最大1個だけ認識し、`ConductorTask.acceptance_timeout_seconds`へ保存する。省略時はconductor環境値を使う。
- `ConductorTask`の既存8引数constructorは環境既定値を補う互換入口として残し、retry時は元taskのtimeout値を明示的に引き継ぐ。

#### `TaskAcceptanceWindow`

- fieldsは`started_ns::UInt64`、`deadline_ns::UInt64`、`timeout_seconds::Float64`。
- `acceptance_timeout_nanoseconds(seconds)::UInt64`は秒を切上げでnsへ変換し、overflowは`typemax(UInt64)`へ飽和させる。
- `acceptance_deadline_ns(started_ns, seconds)::UInt64`も加算overflowを飽和させる。
- `task_acceptance_windows::Dict{String,TaskAcceptanceWindow}`を既存`task_runtime_states_lock`で保護する。
- `register_task_acceptance_window!(task_id, seconds; now_ns=time_ns())`は未登録時だけwindowを作り、再queue時は開始時刻・deadlineを変更せず既存値を返す。
- `get_task_acceptance_window(task_id)::Union{Nothing,TaskAcceptanceWindow}`はread-only snapshotを返す。
- `enqueue_task!(task; now_ns=time_ns())`はtaskの初回queued登録とwindow登録後にqueueへpushする。禁止遷移ではpushしない。

#### 期限判定

- `acceptance_deadline_reached(task_id; now_ns=time_ns())::Bool`はwindowがあり`now_ns >= deadline_ns`の場合だけtrue。
- `expire_waiting_tasks!(; now_ns=time_ns())`は同一snapshot時点でqueue全体と`dispatch_unknown` registryを確認する。
- `queued`かつ期限到達したtaskはqueueの位置に関係なく除去し、`terminal_kind=QUEUE_TIMEOUT`、`reason=worker_acceptance_deadline_exceeded`へ1回だけ遷移して`TASK_QUEUE_TIMEOUT`を記録する。
- `dispatch_unknown`かつ期限到達したtaskは`terminal_kind=DISPATCH_OUTCOME_UNKNOWN`、`reason=worker_acceptance_outcome_unknown_at_deadline`へ1回だけ遷移して同名eventを記録する。
- unknown terminal後はtask ID一致・job ID未確定のnode予約だけを`NODE_DOWN`へ解放する。他taskの割当ては変更しない。
- 戻り値は`(queue_timeout_count, outcome_unknown_count)`。callback送信はStep 10まで行わない。

#### dispatch ACK timeoutと後着応答

- `dispatch_to_worker`、`dispatch_queued_tasks`、`run_dispatch_cycle!`へ試験用keyword `dispatch_timeout_seconds`と`monotonic_clock::Function=time_ns`を通す。既定挙動は現行3秒と単調時計。
- ACK待ち時間はdispatch timeoutと残り受付期限の小さい方とする。
- ACK timeout時は自予約を保持したままtaskを`dispatch_unknown`へ遷移し、`DISPATCH_OUTCOME_UNKNOWN_PENDING`を記録して`DISPATCH_OUTCOME_UNKNOWN`を返す。通常failure catch、retry、node downへ流さない。
- `dispatch_queued_tasks`はunknown outcomeをqueueへ戻さず、そのcycleをreturnする。
- `start_unknown_dispatch_watcher!(dispatch_task, task, node; monotonic_clock)`はtaskがunknownである間だけ、元request taskの終了または受付deadlineまで待つ。
- 期限前の遅延`OK|STARTED|job_id`はtaskを`dispatch_unknown -> running`へ移し、同じnode予約へjob IDを確定して`DISPATCH_LATE_ACK`を記録する。terminal化済みなら無視し再配送しない。
- 期限前の遅延BUSYは自予約を割当てなしbusyへ移し、taskを`dispatch_unknown -> queued`へ戻して`DISPATCH_LATE_BUSY`を記録する。明示的BUSY以外の遅延errorはunknownのままにする。
- watcher自身がdeadlineへ達した場合は`expire_waiting_tasks!`を呼ぶ。periodic dispatch cycleとの競合はtask terminal first-write-winsとtask ID付き予約解放で吸収する。
- 対応DONEが先に来た場合は既存early-DONEがnodeを解放し、taskをterminalにする。watcherはterminalを見て後着ACKを適用しない。

#### 試験

- `test/regression_conductor_queue_deadline.jl`で既定14400秒、環境上書き、per-submit parse、開始/deadline保存、BUSY/idleなしでの不変、LIFO内部の期限切れ除去、running非期限切れ、不正値を確認する。
- `test/regression_conductor_dispatch_timeout.jl`で応答保留後にunknown・予約保持・queue 0・request 1件を確認し、追加cycleでもrequestが増えないことを確認する。
- 同試験で期限前の遅延ACK、期限前のearly DONE、明示的遅延BUSY後の安全なqueue復帰、deadline後のunknown terminalと予約downを個別workerで確認する。
- 既存BUSY待機、task lifecycle、client protocol、予約、DONE identity回帰も再実行する。

### Phase 3: 実装する — 完了

- clientへtimeout正値validationと`ACCEPTANCE_TIMEOUT_SECONDS=` SUBMIT fieldを追加し、単体submitとwait wrapperの両方から指定できるようにした。
- `ConductorTask`へ受付timeoutを追加し、旧8引数constructorは環境既定値を補う互換入口として維持した。retry taskは元値を引き継ぐ。
- conductorへ既定14400秒、環境値取得、秒からnsへの飽和変換、絶対deadline計算を追加した。
- `TaskAcceptanceWindow`とregistryを追加し、初回enqueueだけで単調時刻の開始・deadlineを保存するようにした。
- queue全体の`QUEUE_TIMEOUT`と`dispatch_unknown`の`DISPATCH_OUTCOME_UNKNOWN`を同じ期限走査でterminal化し、unknownの自予約だけをdownへ解放するようにした。
- dispatch ACK timeout時は通常failure catchへ送らず、taskをunknown、nodeをreserved、queueを空のまま保持するようにした。配送loopは再投入せずreturnする。
- 元request taskをdeadlineまで追うwatcherを追加し、遅延ACK、early DONE、遅延BUSY、遅延protocol/transport failureを別々に処理するようにした。
- 明示的遅延BUSY用に`dispatch_unknown -> queued`だけを許可遷移へ追加し、lifecycle遷移行列試験を追従させた。
- `test/regression_conductor_queue_deadline.jl`と`test/regression_conductor_dispatch_timeout.jl`を追加した。controlled workerは既存の「response channelへ値を入れるまで保留」機構で要件を満たすため変更していない。
- `syncopadeConductor.jl`のincludeとper-submit parse smokeはexit `0`、`STEP8_INCLUDE_OK`。`git diff --check`もerrorなし。機能検証はPhase 4で行う。

### Phase 4: テストまたは検証を行う — 完了

#### 初回検証と強化C補正

- queue deadline回帰は初回からexit `0`、`43 / 43 pass`となった。
- dispatch timeout回帰の初回はexit `1`、`5 pass / 3 fail / 1 error`で停止した。1秒deadlineのtaskがtimeout直後の確認時にはterminal、node downとなり、遅延ACK待ちもtimeoutした。
- 保存windowの差分は正しく`1_000_000_000 ns`だった。切分け用実TCP smokeで、`run_dispatch_cycle!`が0.05秒指定に対して約0.85秒を要し、watcherがdeadlineまで呼出元を実質待たせていることを確認した。
- 原因は、同じevent loopの`@async` watcher内で`Base.timedwait`した構造と、初回JIT時間を1秒deadlineへ含めた試験値だった。watcherを短い`sleep`でyieldする状態loopへ変え、呼出元を待たせない形にした。遅延ACK/BUSY/DONE用deadlineはJITより十分長い5秒、unknown終端だけ0.5秒とした。
- 同じ初回でlog writerのflush残時間が1ms未満になり、`Base.timedwait`の最小`pollint`制約に反する既存境界も検出した。`pollint`を最低1msへclampし、logを失わずwriterが継続するよう局所補正した。
- さらに1ms未満のdispatch timeout指定でも同じ制約違反にならないようACK待ち側も最低1msへclampした。
- 遅延BUSYがdeadline後に確定した枝でも、terminal reasonを通常の`worker_acceptance_deadline_exceeded`へ統一し、`TASK_QUEUE_TIMEOUT`を必ず記録するよう補った。

#### 最終検証

- `test/regression_conductor_queue_deadline.jl`を補正後2回実行し、いずれもexit `0`、`43 / 43 pass`、`STEP8_QUEUE_RESULT=PASS_ACCEPTANCE_DEADLINE`。
- 永続queue artifactは`/tmp/syncopade-step8-queue-recheck.q1fyln/conductor_events.csv`、SHA-1は`0225bf358054cd37453f4cd0133e77a7bc82c957`。
- 既定14400秒、環境7200.5秒、per-submit 12.5秒とwire 7.5秒、無効値、ns overflow飽和、初回window不変、期限直前保持、期限一致terminal、LIFO内部除去、running非期限切れを確認した。
- `test/regression_conductor_dispatch_timeout.jl`を補正後3回実行し、すべてexit `0`、`40 / 40 pass`、`STEP8_DISPATCH_RESULT=PASS_OUTCOME_UNKNOWN`。
- 永続dispatch artifactは`/tmp/syncopade-step8-dispatch-recheck.zxZPta/conductor_events.csv`、SHA-1は`4992bddfa1c088d30810290561ca03debfe048a6`。
- 4 taskはいずれもACK timeoutまでworker request 1件だけだった。追加dispatch cycleでもrequestは増えなかった。
- 遅延ACKは同じtask/nodeでrunning、early DONEは後着ACKで巻戻らずterminal、遅延BUSYはretry増加なしでqueue 1件、deadline不明は`DISPATCH_OUTCOME_UNKNOWN`かつnode downとなった。
- artifact eventは`DISPATCH_OUTCOME_UNKNOWN_PENDING=4`、`DISPATCH_LATE_ACK=1`、`DISPATCH_LATE_BUSY=1`、`DISPATCH_OUTCOME_UNKNOWN=1`、`DISPATCH_FAILED=0`。
- `test/regression_conductor_busy_wait.jl`: exit `0`、`48 / 48 pass`。
- `test/unit_conductor_task_lifecycle.jl`: exit `0`、`145 / 145 pass`。
- `test/unit_client_protocol.jl`: exit `0`、`63 / 63 pass`。
- `test/unit_conductor_dispatch_reservation.jl`: exit `0`、`29 / 29 pass`。
- `test/regression_conductor_done_identity.jl`: exit `0`、`33 / 33 pass`。
- `test/regression_conductor_stale_idle.jl`: exit `0`、`26 / 26 pass`、artifact `/tmp/syncopade-step8-stale.PTntce`。
- `test/reproduction_conductor_silent_drop.jl`: exit `0`、`11 / 11 pass`、artifact `/tmp/syncopade-step8-silent.7OsAhR`。
- `test/unit_conductor_queue.jl`: repository外log指定でexit `0`、`17 / 17 pass`。
- `git diff --check`はerrorなし。
- repository log SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`のままで、先生の既存差分4行を変更していない。

### Step 8結論

worker未送信のqueue待ちは初回受付からの単調deadlineで`QUEUE_TIMEOUT`となる。request送信後にACKがないtaskは再配送せず`dispatch_unknown`で保持され、遅延ACK/DONE/BUSYを同じtaskへ照合し、最後まで不明な場合だけ`DISPATCH_OUTCOME_UNKNOWN`となる。正常ACK後のworker実行時間には期限を掛けていない。

---

## Step 9: task ID付き結果protocolを追加する — 完了

### 目的

conductor経由のworker結果をconductor task IDへ直接結び付け、成功、worker実行失敗、worker未受理のconductor失敗を同じtask単位で識別可能にする。

### 対象ファイル

- `syncopadeClient.jl`
- `syncopadeServer.jl`
- `src/Syncopade.jl`
- `test/unit_client_protocol.jl`
- `test/unit_server_admission_state.jl`
- task結果protocol用の新規単体試験候補
- このTodo

### 完了条件

- conductor経由のcallback payloadにtask IDとjob IDを別々に含める。
- worker未受理の結果ではjob IDなしを明示的に表現できる。
- 公開client parserは旧`RESULT`と新しいtask結果を判別し、新形式ではtask IDを返す。
- 直接worker投入の旧`RESULT|job_id|...`を維持する。
- malformed payload、task ID欠落、status不正を正常結果として受理しない。

### 検証方法

1. 新形式の成功、worker実行失敗、job IDなし失敗を単体解析する。
2. 旧形式の成功・失敗が従来どおり解析できることを確認する。
3. conductor metadata付きworker jobだけが新形式を送ることを確認する。
4. public export、docstring、既存client/server protocol試験を確認する。

### Phase 1: 実装方針をまとめる — 完了

- 旧形式`RESULT|job_id|...`を変更せず、新形式を別prefix `TASK_RESULT`として追加する。field位置を流用せず、task IDとjob IDを常に別fieldにする。
- 新形式は成功`TASK_RESULT|task_id|job_id|OK|value`、失敗`TASK_RESULT|task_id|job_id|ERROR|error_type|error_message`とする。worker未受理のconductor終端ではjob ID fieldを空にできる。
- workerは`SyncopadeJob`にtask ID・conductor IP・conductor portが全て揃う場合だけconductor経由と判定し、新形式を親へ送る。直接投入またはmetadata不完全なjobは旧形式を維持する。
- clientに旧・新形式を一つの具体型へ正規化する純粋parserを置く。protocol種別、task ID、job ID、成功可否、payloadを返し、field不足、空必須ID、status不正を例外にする。
- 既存`syncopade_result_server`とone-shot serverは共通parserを使う。旧3引数handlerを維持しつつ、新形式では4引数`(task_id, job_id, ok, payload)`を優先し、旧handlerしか適用できない場合は従来3引数で配送する。
- `submit_conductor_task_and_wait`は新形式ならcallbackのtask IDがSUBMIT受付IDと一致することを必須にする。旧workerとの移行互換のため旧RESULTも受理し、その場合だけ受付IDを既存どおり補う。
- server送信payload生成をsocket I/Oから分け、直接jobとconductor jobの成功・失敗をnetworkなしで照合できるようにする。
- Step 9ではworker実行結果のprotocolだけを変更する。worker未受理のterminal callback送信、重複抑止、callback成否保存はStep 10まで実装しない。
- 純粋parser、pure payload builder、handler arity、実loopback送信、public exportを小テストで確認し、既存server排他とclient protocolを回帰する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### `SyncopadeResultMessage`

- fieldsは`protocol::Symbol`、`task_id::String`、`job_id::String`、`ok::Bool`、`payload::String`。
- `protocol`は`:legacy_result`または`:task_result`だけとする。
- 旧形式ではtask IDを空、job IDを非空とする。新形式ではtask IDを非空とし、成功時のjob IDは非空、失敗時は空を許す。
- 成功payloadはvalue、新旧失敗payloadは`error_type|error_message`へ正規化する。

#### `parse_syncopade_result_payload(payload::AbstractString)::SyncopadeResultMessage`

- `split(...; keepempty=true)`を使い、旧`RESULT|job_id|OK|value...`と`RESULT|job_id|ERROR|type|message...`を解析する。
- 新`TASK_RESULT|task_id|job_id|OK|value...`と`TASK_RESULT|task_id|job_id|ERROR|type|message...`を解析する。
- valueとerror message内の`|`は末尾field列をjoinして復元する。
- 旧job ID、新task ID、新成功job ID、error typeの空文字、未知prefix、未知status、field不足は`ArgumentError`。
- checksum検証やsocket I/O、handler呼出しは行わない。

#### `invoke_syncopade_result_handler(handler, message)::Nothing`

- `:task_result`では4引数`handler(task_id, job_id, ok, payload)`がapplicableなら優先する。なければ既存3引数`handler(job_id, ok, payload)`へfallbackする。
- `:legacy_result`では既存3引数を優先する。4引数しかない場合は空task IDを第1引数として呼ぶ。
- どちらも適用不能なら`MethodError`とし、result server側の既存error処理へ流す。

#### worker payload生成

- `has_conductor_metadata(job::SyncopadeJob)::Bool`はtask ID非空、conductor IP非空、conductor port正値の積で判定し、副作用を持たない。
- `build_result_payload(job, job_id, ok; result="", errType="", errMsg="")::String`はjob IDを必須とする。
- conductor metadataが揃えば`TASK_RESULT`、それ以外は`RESULT`を先頭にする。成功は`OK|result`、失敗は非空error typeと`ERROR|type|message`を付ける。
- `send_result`はbuilder結果へ従来checksumを付けて送るだけとし、接続・Bool戻り値契約を維持する。

#### result serverとwait wrapper

- `syncopade_result_server`と`syncopade_result_server_once`はchecksum成功後に共通parserとhandler dispatcherを呼ぶ。旧3引数handlerの既存挙動は維持する。
- `submit_conductor_task_and_wait`は共通parserを使い、新形式では`message.task_id == submitted_task_id`を必須にする。不一致は`ArgumentError`。
- 新形式の戻り値はmessage内task/job IDを返す。旧形式はsubmitted task IDとmessage job IDを返し、既存NamedTuple shapeを維持する。

#### 試験

- `test/unit_result_protocol.jl`を新設し、旧成功・失敗、新成功・worker失敗・空job IDのconductor失敗、delimiter復元、malformedを確認する。
- 同試験でmetadataなし・完全・不完全jobのpure builder、3/4引数handler互換、直接jobとconductor jobのloopback送信を確認する。
- `test/unit_server_admission_state.jl`にはmetadata完全性判定の最小回帰を追加する。
- `test/unit_client_protocol.jl`、package export smoke、server admission回帰を実行する。

### Phase 3: 実装する — 完了

- clientへ`SyncopadeResultMessage`、旧/new共通parser、3/4引数handler dispatcherを追加した。
- continuous/one-shot result serverの重複解析を共通parserへ置換し、旧3引数handlerを維持しつつtask-aware 4引数handlerを受けられるようにした。
- `submit_conductor_task_and_wait`も共通parserへ接続し、新形式のtask ID一致を必須、旧形式は受付ID補完の互換経路とした。
- package exportへ結果message型とparserを追加した。
- workerへconductor metadata完全性判定とpure result builderを追加し、完全metadataだけ`TASK_RESULT`、直接・不完全metadataは旧`RESULT`を生成するようにした。
- `send_result`はbuilder出力へ従来checksumを付ける構造へ変更し、接続とBool戻り値は維持した。
- `test/unit_result_protocol.jl`を追加し、旧/new parser、空job IDのconductor失敗、malformed、builder、handler arity、実loopback送信を検証する構成にした。
- `test/unit_server_admission_state.jl`へmetadata完全・なし・不完全の判定を追加した。
- client/server include smokeはどちらもexit `0`、`STEP9_CLIENT_INCLUDE_OK`、`STEP9_SERVER_INCLUDE_OK`。`git diff --check`もerrorなし。機能検証はPhase 4で行う。

### Phase 4: テストまたは検証を行う — 完了

#### 初回検証と強化C補正

- `test/unit_result_protocol.jl`は初回からexit `0`、`37 / 37 pass`となった。
- worker wire metadataからtask情報を抽出する実経路のassertionを6件追加し、pure builderへ手作業で完全jobを渡すだけでなく、`convMSG2JOB`から新形式へ接続することを確認する構成へ強化した。
- packageはprecompileとexport確認まで成功したが、灯子のdocstring検査commandがJulia 1.12の`Base.Docs.doc`を型、次にBindingへ直接呼ぶ誤った使い方で2回`MethodError`となり、続くmeta keyの比較方法も1回`AssertionError`となった。
- 製品コードやdocstring欠落ではなく検査commandのAPI理解ミスだった。`Base.Docs.meta(Syncopade)`のBinding keyをmoduleとsymbolで照合する読取りへ直し、同じ公開面検査を完了した。

#### 最終検証

- `test/unit_result_protocol.jl`を追加assertion後2回実行し、いずれもexit `0`、`43 / 43 pass`、`STEP9_RESULT=PASS_RESULT_PROTOCOL`。
- 旧成功・失敗、新成功・worker失敗、空job IDのconductor失敗、payload内`|`復元、malformed 10種を確認した。
- metadataなしjobと不完全jobは`RESULT`、完全metadata jobは`TASK_RESULT`となった。wire metadataはuser argsから除去され、task/conductor情報へ保存された。
- 3引数handlerは新形式からjob ID・結果を受け、4引数handlerは新形式のtask IDを受ける。4引数handlerへ旧形式を渡す場合は空task IDとなった。
- loopback実送信で、直接jobは旧形式成功、conductor jobはtask/job ID付き新形式失敗をchecksum検証後に解析できた。
- `test/unit_server_admission_state.jl`: `--threads=4`、exit `0`、`16 / 16 pass`。
- `test/unit_client_protocol.jl`: exit `0`、`63 / 63 pass`。
- `test/unit_controlled_worker_fixture.jl`: exit `0`、`23 / 23 pass`。
- package precompile、export、doc metadata検査はexit `0`、`STEP9_PUBLIC_API=PASS`。
- `git diff --check`はerrorなし。
- repository log SHA-1は`528443adeeff16bfcd482c552458584d7a080e99`のままで、先生の既存差分4行を変更していない。

### Step 9結論

直接worker投入の旧`RESULT`は維持され、conductor metadataが完全なworker結果だけが`TASK_RESULT`でtask IDとjob IDを別々に返す。公開parserは旧・新を同じ型へ正規化し、worker未受理のjob ID空失敗も表現できる。conductor自身がその失敗callbackを送る処理はStep 10へ残した。

---

## Step 10: conductor打切りを親へ一度だけ通知する — 完了

### 目的

worker job IDが発行されないままconductorがtaskをterminalにした場合も、親がtask ID、終端種別、理由を受け取れるようにする。

### 対象ファイル

- `syncopadeConductor.jl`
- `syncopadeClient.jl`
- `test/reproduction_conductor_silent_drop.jl`（修正後回帰試験へ変更・改名候補）
- terminal通知用の新規単体試験候補
- このTodo

### 完了条件

- retry上限、`QUEUE_TIMEOUT`、`DISPATCH_OUTCOME_UNKNOWN`が共通のterminal処理を通る。
- terminal callbackはtask ID、空のjob ID、失敗種別、理由を含む。
- callback送信成否をtask状態と監査logへ保存する。
- 同じtaskを二度terminal化してもcallback送信と終端確定は1回だけである。
- callback受信と状態照会を併用しても、公開client側でtask ID単位に同じ終端として扱える。

### 検証方法

1. 修正前のsilent drop試験を反転し、親が長いtimeout前にtask ID付き失敗を受信することを確認する。
2. 複数taskのうち該当taskだけが失敗となり、他taskの結果を取り違えないことを確認する。
3. terminal処理を重複呼出しし、callback 1件、terminal log 1件であることを確認する。
4. callback先不通でも状態照会から同じ終端種別と理由を取得できることを確認する。

### Phase 1: 実装方針をまとめる — 完了

- retry上限、queue deadline、dispatch outcome unknownの3経路を、task terminal確定と親通知を一体で扱う共通関数へ集約する。worker DONEは既にworkerが結果callbackを送るため、このconductor打切り通知の対象外とする。
- conductorは初回enqueue時の`ConductorTask`をtask ID別に保持し、queueから消えた後もcoordinator IP/portへ通知できるようにする。retryでは同じ受付taskの最新版を保持する。
- terminal確定と「callback送信権の取得」を同じtask lock内でfirst-write-winsにする。送信自体はlock外で行い、重複terminal呼出しは送信前に拒否する。
- callbackはStep 9の`TASK_RESULT|task_id||ERROR|terminal_kind|reason`を使い、worker未受理なのでjob IDを空fieldにする。親からのACKは要求せず、write完了を送信成功とする。
- callback試行状態はtask lifecycleと同じ同期境界で別recordに保持し、未試行、送信中、成功、失敗と失敗理由を区別する。process内で同じtaskへ再試行・二重送信はしない。
- 共通terminal関数はtask状態を先に確定するため、callback接続失敗でも状態照会のterminal kind/reasonは失われない。監査logにはterminal確定、callback成否、宛先、理由を1件だけ残す。
- queue期限走査は候補抽出後に共通terminal関数でclaimし、成功したtaskだけqueueから除去する。unknown期限も同関数でclaim後、自taskのnode予約だけをdownへ解放する。
- 遅延BUSYがdeadline後に届く枝は直接terminal stateを書かず、共通terminal関数へ渡して通知漏れを防ぐ。
- 修正前silent-drop試験は正方向へ反転・改名し、長い親timeoutを待たずtask ID付きcallbackが届くこと、job ID空、状態照会一致、重複送信なしを確認する。
- 別単体試験でcallback先不通でもterminal照会できることと、複数taskの非対象側へ接続しないことを確認する。Step 9 parserをそのまま正本としてcallbackを解析する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### task recordと通知状態

- `conductor_task_records::Dict{String,ConductorTask}`と`task_terminal_notifications::Dict{String,TaskTerminalNotificationState}`を既存`task_runtime_states_lock`で保護する。
- `TaskTerminalNotificationState`のfieldsは`status::Symbol`、`callback_ok::Bool`、`error::String`。statusは`:sending`、`:succeeded`、`:failed`だけを保存し、未試行は辞書entryなしで表す。
- `register_conductor_task_record!(task)::Nothing`は初回enqueueとretry enqueueで同じtask IDのrecordを保存する。coordinator、function、受付timeoutは同一であることを確認し、retry countだけ最新版へ更新する。不一致は`ArgumentError`。
- `get_conductor_task_record(task_id)::Union{Nothing,ConductorTask}`と`get_task_terminal_notification_state(task_id)::Union{Nothing,TaskTerminalNotificationState}`はread-only snapshotを返す。
- `enqueue_task!`はqueued stateとacceptance windowの登録後、queue push前にtask recordを登録する。

#### callback payloadと送信

- `conductor_terminal_callback_payload(task_id, terminal_kind, reason)::String`は`TASK_RESULT|task_id||ERROR|terminal_kind|reason`を返す。task IDとterminal kindは非空必須。
- `send_conductor_terminal_callback(task, terminal_kind, reason)`はpayloadへ既存checksumを付け、`coordinator_ip:coordinator_port`へ1行送信してsocketを閉じる。
- 戻り値は`(ok::Bool, error::String)`。connect/write成功は`ok=true`、例外は`ok=false`と`showerror`文字列を返し、例外を外へ送出しない。

#### `finalize_conductor_task!`

- signatureは`finalize_conductor_task!(task_id, terminal_kind, reason; expected_states)::Bool`。
- `expected_states`は呼出し経路が許す非terminal state tuple。現在stateが含まれず、未知task、既存terminal、通知entry既存なら`false`で副作用なし。
- claim時はtask lock内で`mark_task_terminal!`を行い、通知状態を`:sending`として先に保存する。task record欠落でもterminalは維持し、送信結果を`:failed`、理由`missing_conductor_task_record`とする。
- lock外でcallbackを1回だけ送り、同じ通知entryを`:succeeded`または`:failed`へ更新する。
- `TASK_TERMINAL` eventを1件だけ記録し、task ID、endpoint、terminal kind/reason、`callback_ok`、送信errorを残す。
- 戻り値trueはterminal claim成功を表し、callback成功そのものとは区別する。

#### 既存terminal経路

- `requeue_with_retry!`の上限超過は`expected_states=(TASK_RESERVED,)`で`MAX_RETRY_EXCEEDED`を共通関数へ渡し、従来`TASK_DROPPED`も1件維持する。
- queue deadlineは`expected_states=(TASK_QUEUED,)`で`QUEUE_TIMEOUT`を共通関数へ渡し、claim成功後だけ同task IDをqueueから除去して`TASK_QUEUE_TIMEOUT`を記録する。
- unknown deadlineは`expected_states=(TASK_DISPATCH_UNKNOWN,)`で`DISPATCH_OUTCOME_UNKNOWN`を共通関数へ渡し、claim成功後だけ自予約をdownへ解放して従来eventを記録する。
- deadline後の遅延BUSYも直接`mark_task_terminal!`せず、`:expired`判定後に共通関数へ渡す。
- worker DONEの`WORKER_DONE_OK/ERROR`は共通conductor callbackを呼ばず、現行worker callbackとtask terminal更新を維持する。

#### 試験

- `test/reproduction_conductor_silent_drop.jl`を`test/regression_conductor_terminal_callback.jl`へ改名し、retry上限で2秒以内に新形式callback 1件を受信する正方向試験へ反転する。
- 同回帰でtask ID一致、job ID空、`MAX_RETRY_EXCEEDED|max_retry_exceeded`、状態照会一致、`TASK_TERMINAL=1`、重複finalize後の2件目接続なしを確認する。
- 新規`test/unit_conductor_terminal_callback.jl`で閉じたcallback portへの送信失敗状態、status fallback、別task listener非接続、queue timeout、outcome unknownの共通経路を確認する。
- Step 8 deadline/dispatch timeout、Step 9 result protocol、task lifecycle、DONE identityを再実行する。

### Phase 3: 実装する — 完了

- `syncopadeConductor.jl`へtask definition snapshotとterminal callback試行状態を追加し、初回enqueueからretryまで同じtask IDの通知先を保持するようにした。
- `finalize_conductor_task!`でtask terminal遷移と送信権を同じlock内でclaimし、lock外でtask ID付き失敗callbackを1回だけ送るようにした。送信失敗時もterminal stateと失敗理由を保持する。
- retry上限、queue deadline、dispatch outcome unknown、deadline後の遅延BUSYを共通terminal処理へ接続した。worker DONE経路は変更していない。
- silent-drop再現試験を`test/regression_conductor_terminal_callback.jl`へ反転・改名し、`test/unit_conductor_terminal_callback.jl`へcallback失敗、非対象task、queue timeout、unknown deadline、遅延BUSY deadlineの試験を追加した。
- 新しい`TASK_TERMINAL` logのstatus欄をevent名と誤認した既存dispatch試験は、CSVのevent列だけを比較するよう修正した。

### Phase 4: テストまたは検証を行う — 完了

- `julia --startup-file=no --project=. test/regression_conductor_terminal_callback.jl`: 19/19 pass。retry上限で2秒以内にtask ID付き失敗callbackを受信し、空job ID、状態照会一致、重複送信なし、`TASK_TERMINAL=1`を確認した。
- `julia --startup-file=no --project=. test/unit_conductor_terminal_callback.jl`: 51/51 pass。callback先不通時のterminal保持、snapshot非共有、非対象taskへの非接続、queue timeout、dispatch unknown、deadline後の遅延BUSYを確認した。
- `julia --startup-file=no --project=. test/regression_conductor_queue_deadline.jl`: 43/43 pass。
- `julia --startup-file=no --project=. test/regression_conductor_dispatch_timeout.jl`: 40/40 pass。
- `julia --startup-file=no --project=. test/unit_result_protocol.jl`: 43/43 pass。
- `julia --startup-file=no --project=. test/unit_conductor_task_lifecycle.jl`: 145/145 pass。
- `julia --startup-file=no --project=. test/regression_conductor_done_identity.jl`: 33/33 pass。
- 合計374/374 pass、全process exit code 0。Step 10の範囲では未解決errorなし。

---

## Step 11: 修正後回帰試験を統合しlan100で確認する — 完了

### 目的

個別修正を正の回帰試験として統合し、単一PC・conductor 1本・server 1本の実TCPでも正常運転と終端性を確認する。

### 対象ファイル

- `test/runtests.jl`
- Steps 1〜10で追加・変更したtest files
- `docs/TESTING.md`
- このTodo

### 完了条件

- 修正前の誤動作を期待するtest名と期待値が残らず、正しい動作を期待する回帰試験として登録される。
- 全自動test suiteがexit code 0で完了する。
- `lan100`の`192.168.100.30`だけを使い、conductor 1本、server 1本、4 tasksが全てtask ID付き終端へ到達する。
- 実serverの排他が維持され、実行区間の重複がない。
- BUSY経路でもtaskが消えず、正常受理または期限付きterminalへ到達する。
- 起動process、listener、一時fileを残さない。
- sibling repository側で必要になるcallback/API変更点を引渡しに明記する。

### 検証方法

1. Steps 1〜10の単体・決定的回帰試験を個別実行する。
2. `julia --startup-file=no --project=. test/runtests.jl`を実行し、exit code、test数、stderrを記録する。
3. `SYNCOPADE_NODE_PROFILE=lan100`と`SYNCOPADE_WIRED_PREFIX=192.168.100.`でwrapperを起動する。
4. LISTが`192.168.100.30:8030`の1 nodeだけであることを確認してから4 tasksを投入する。
5. task ID、job ID、callback、DONE、terminal状態、実行区間を照合する。
6. server/conductor終了後に使用portを再bindし、残留processがないことを確認する。

### Phase 1: 実装方針をまとめる — 完了

- `test/runtests.jl`は各test fileを同一moduleへ`include`せず、独立Julia processで順に実行する。conductor/server定義とtest helperのglobal名衝突、状態registry、ENV、log writerをtest間で共有しないためである。
- 自動suiteには既存baseline 2件とSteps 1〜10のunit・決定的regression 13件を登録する。外部server/conductorを要求するmanual integrationは混ぜない。
- 各子processは`--startup-file=no --project=<repository> --threads=4`で起動し、stdout/stderrとexit codeを親testが回収する。repository既定logを使う古いqueue testにもsuite専用一時logを与える。
- `unit_conductor_queue.jl`のretry fixtureは、Step 7以降の正規lifecycleどおりenqueue、pop、reservedを経てからrequeueするよう直し、未登録taskを直接requeueする旧前提を除く。
- lan100の既存`integration_conductor_node_exclusivity.jl`は、修正前のoverlap成功条件を正方向へ反転する。4 tasksを既定値にし、task-aware callback、conductor task status、DONE log、worker区間をtask ID/job ID単位で照合する。
- 実TCP試験ではLISTが`192.168.100.30:8030`だけであることを投入前にfail-closedで確認し、4 tasks全てについて正常callback、`WORKER_DONE_OK` terminal、重複なし、実行区間overlap 0、`max_active == 1`を要求する。
- BUSY時のtask保持は決定的`regression_conductor_busy_wait.jl`、実server排他は`integration_server_busy_rejection.jl`、4 taskの終端性はconductor integrationで別々に確認し、自然raceの発生自体は成功条件にしない。
- wrapper processのstdout/stderrとconductor CSVはrepository外の一時artifactへ置く。serverは`q`、conductorはSIGINTでbounded終了し、最後に使用port再bind、対象process不在、repository log不変を確認する。
- `docs/TESTING.md`へ自動suite、lan100正方向integration、task-aware callback/statusの確認項目とcleanup手順を反映する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

#### 自動suite

- `ISOLATED_TEST_FILES::Vector{String}`は`unit_client_protocol`、`unit_conductor_queue`、`unit_conductor_node_state`、`regression_conductor_stale_idle`、`unit_conductor_dispatch_reservation`、`regression_conductor_done_identity`、`unit_controlled_worker_fixture`、`regression_conductor_busy_wait`、`unit_conductor_task_lifecycle`、`regression_conductor_queue_deadline`、`regression_conductor_dispatch_timeout`、`unit_result_protocol`、`unit_server_admission_state`、`regression_conductor_terminal_callback`、`unit_conductor_terminal_callback`の15件とする。
- `run_isolated_test(test_file, artifact_dir)`は子processのstdout、stderr、exit codeを返す。親はstdoutを表示し、exit code 0とstderr空を各fileでassertする。
- suite用`SYNCOPADE_CONDUCTOR_LOG`は`artifact_dir/<test basename>.csv`とし、`finally`でsuite一時directoryを削除する。

#### lan100 integration harness

- `receive_callback(listener)`はchecksum検証後、正本`parse_syncopade_result_payload`を呼び、`task_id`、`job_id`、`ok`、`payload`を返す。
- `main`の既定task countは4、sleepは3秒、timeoutは90秒とする。callback portはbase portから4件を先にbindし、同じgateから4 SUBMITを解放する。
- callbackは全て`:task_result`、`callback.task_id == submitted task_id`、非空かつ一意なjob ID、成功payloadのlabel一致を要求する。
- `wait_for_conductor_events`は各task IDの`DISPATCH_OK`と`TASK_DONE`を待つ。各行のworker endpoint、task ID、job ID、status、callback成否を照合する。
- event確認後、`query_conductor_task_status`で4件全てが`KnownConductorTaskStatus`、state `:terminal`、kind `WORKER_DONE_OK`、callbackと同じjob IDであることを要求する。
- fixture nanosecond区間とconductor DONE時刻区間はともにoverlap pair 0、全probeの`active_at_entry == 1`かつ`max_active == 1`を要求する。
- stdout markerは`STEP11_RESULT=PASS_LAN100_EXCLUSIVE_TERMINAL`とし、4組のtask ID/job ID、BUSY/requeue/drop/terminal件数、区間を出力する。

#### 実processとcleanup

- conductor: profile `lan100`、wired prefix `192.168.100.`、一時CSVを指定して`scripts/run_conductor.jl`を起動する。
- server: 同じprofile/prefixと`SYNCOPADE_MOUNT_ROOT_UNIX=<repository>/test/fixtures`を指定して`scripts/run_server.jl`を起動する。
- readinessは各10秒以内の`STATUS|idle`、`NODES|192.168.100.30:8030`。不一致ならtaskを投入しない。
- integration commandは`julia --startup-file=no --project=. test/integration_conductor_node_exclusivity.jl 192.168.100.30 9030 192.168.100.30 8030 4 <callback_base> 1.0 30.0 <conductor_csv>`。
- 終了後は8030、9030、4 callback portsを再bindし、server/conductor process終了、repository log hash不変、stderr内容、CSV hashを記録する。

### Phase 3: 実装する — 完了

- `test/runtests.jl`を15 test fileの独立process runnerへ変更し、各processのexit code 0とstderr空を親testで検査するようにした。suite用log directoryは終了時に削除する。
- `test/unit_conductor_queue.jl`へ一時logとcleanupを追加し、retry fixtureをenqueue/reserved経由の正規task lifecycleへ修正した。
- `test/integration_conductor_node_exclusivity.jl`を4 taskの正方向試験へ反転し、Step 9 parserによるtask-aware callback、task ID/job ID、terminal status、DONE log、排他的実行区間を照合するようにした。
- 修正前の`PASS_REPRODUCED`、overlap必須条件、既定20 tasksを除き、`STEP11_RESULT=PASS_LAN100_EXCLUSIVE_TERMINAL`、overlap 0、`max_active == 1`を成功条件にした。
- `docs/TESTING.md`へ独立process suiteの実行方法、lan100のserver/conductor/4-task command、task-aware確認項目、cleanup手順を追記した。
- integration harnessの初回includeで文字列補間内の引用符によるParseErrorを検出した。検証値を事前変数へ分離する局所修正後、include-onlyは`STEP11_HARNESS_INCLUDE_OK`、exit code 0となった。Todo・前提・仕様変更はない。

### Phase 4: テストまたは検証を行う — 完了

#### 全自動suite

- command: `julia --startup-file=no --project=. --threads=4 test/runtests.jl`。
- 15個の独立子processは全てexit code 0、stderr 0 byte。子testは合計654/654 assertions pass、親runnerは30/30 assertions pass。
- BUSY決定試験は同じtask ID/retry 0のまま3回`ERROR|BUSY`を受け、4回目に正常受理してDONEへ到達した。48/48 pass。
- retry上限、queue timeout、dispatch unknown、callback不通、遅延BUSY deadlineを含むterminal callback試験は70/70 pass。
- suite配下へ子artifactを集約する補正後に全体を再実行し、suite一時directoryの削除を確認した。

#### lan100 preflightと実server BUSY

- このPCが`192.168.12.2`と`192.168.100.30`を保持し、開始前に8030、9030、9141〜9143、9261〜9264のlistenerと既存Syncopade processがないことを確認した。
- server `192.168.100.30:8030`は`STATUS|idle`、conductor `192.168.100.30:9030`のLISTは`NODES|192.168.100.30:8030`だけだった。起動時stderrは両方0 byte。
- `integration_server_busy_rejection.jl`はexit code 0、stderr 0 byte、`PASS_BUSY_REJECTED`と`PASS_NORMAL_RECOVERY`。job A中のBは`ERROR|BUSY`でjob ID/callbackなし、終了後のjob Cは正常受理された。
- job A/Cは`active_at_entry=1`、`max_active=1`、実行区間overlapなし。最終server状態は`STATUS|idle`。

#### conductor経由4 tasks

- result: `STEP11_RESULT=PASS_LAN100_EXCLUSIVE_TERMINAL`、exit code 0、stderr 0 byte。
- submitted 4、task-aware callbacks 4、`KnownConductorTaskStatus(:terminal)` 4、`TASK_DONE` 4、drop 0、conductor failure terminal 0。
- task/job mapping:
  - `291e0045-55e1-486c-aef4-30a8c2e5e8a7` -> `9bf402bd-d608-42d0-8229-20b4ea062837` (`run-0001`)
  - `0af25f7c-8d31-4e80-86f8-df5bfe2f7108` -> `56af2b4c-982f-4117-a611-83c6d92fe375` (`run-0002`)
  - `e76c4c31-6cfc-4164-bef4-b48f5cec37a7` -> `75dbbaf8-171c-4126-955f-a62ff20ec026` (`run-0003`)
  - `152634b4-4306-4a4a-ac14-10337f0fa2fe` -> `8618ea6d-63f0-4aa2-b96a-54e8b7913606` (`run-0004`)
- 4 taskとも`WORKER_DONE_OK`、callback/status/DONEのtask IDとjob IDが一致した。`active_at_entry=1`、`max_active=1`、fixture/conductor区間overlap pairはともに0。
- この実行では`DISPATCH_BUSY=0`、`TASK_REQUEUED_BUSY=0`だった。自然raceを必須にせず、BUSY保持は上記48/48の決定試験、実server排他は直接BUSY試験で確認した。

#### cleanupとevidence

- serverは`q`でexit code 0。conductorは試験完了後のSIGINTで停止し、stderr 2292 byteは`signal 2: Interrupt`の終了traceだけで、試験中runtime errorではない。
- 8030、9030、9141〜9143、9261〜9264は停止後すべて再bind成功。対象Syncopade processは残っていない。
- repository logは試験前後ともSHA-1 `b42bd0dc80df7523ceaaf760fa11e8f36fcaac1b`で、先生の既存4行差分を変更・stageしていない。
- evidence SHA-256: BUSY stdout `764318fbbad58f4c0a46643e3fcfab0010b3ecb5da7204daf74dd97adc816307`、4-task stdout `c4cf45a461a3d582c98c9bbcb93ec3a3e4db76ccfd97582263b002a2b0074945`、conductor CSV `4a2d95ddbd11f833ebf177b09ab2dbd3aad952b00a0109a2f0c0a91c26302b16`。
- repository外artifact `/tmp/syncopade-step11-lan100.MYvdVS`はhash記録後に削除し、不在を確認した。
- harness include時の引用符ParseErrorと、監査shellでzsh予約配列`path`を上書きしたcommand errorは、どちらも灯子の局所ミスだった。仕様・実験結果を変えずに修正して再実行し、最終結果は上記のとおり全てpassした。

---

## 完了時の引渡し

- 原因ごとの修正内容と、不変条件を守る状態遷移
- 変更した公開APIとwire protocol
- task IDを使った成功・失敗・照会方法
- BUSY、通信失敗、受付成否不明、queue期限切れの扱いの違い
- 実行したtest command、assertion数、exit code、artifact hash
- `lan100`統合試験のtask ID/job ID対応と実行区間
- 実稼働conductor/workerへ反映する際の必要手順
- sibling repository側で必要な最小変更
- local HEAD、`origin/master`、commit一覧
- version更新・tag・releaseは別途先生の指示を待つ

### 実績

- 原因は、node観測と予約の世代管理不足、dispatch前の非原子的選択、BUSYと通信失敗の未分類、task lifecycle/受付期限/親terminal通知の欠落が重なっていたこと。node reservation、task state machine、期限、task-aware result、first-write-wins terminal callbackへ分離して修正した。
- 保持する不変条件は、1 nodeに同時に1 taskだけを予約すること、stale観測でactive assignmentを上書きしないこと、BUSYでretry countを増やさずtaskを保持すること、受付成否不明では同じtaskを再送しないこと、terminal callbackを最大1回だけ送ること。
- 公開client APIは`ConductorTaskStatus`、`KnownConductorTaskStatus`、`UnknownConductorTaskStatus`、`query_conductor_task_status`、`SyncopadeResultMessage`、`parse_syncopade_result_payload`。SUBMITには任意の`ACCEPTANCE_TIMEOUT_SECONDS`を追加した。
- wire callbackはworker受理後の`TASK_RESULT|task_id|job_id|OK/ERROR|...`と、worker未受理terminalの`TASK_RESULT|task_id||ERROR|terminal_kind|reason`。legacy `RESULT` parserと3引数handlerは互換維持する。
- sibling repositoryはSyncopade依存をこの修正版へ更新し、可能なら4引数result handler `(task_id, job_id, ok, payload)`または`submit_conductor_task_and_wait`を使う。長時間taskは900秒固定にせず、実行時間を含む十分な`acceptance_timeout_seconds`を明示する。
- 実稼働へ反映する際はconductor/serverを同じrevisionへ更新して再起動し、task code更新を伴う場合は全node cache clearで`failed_nodes == 0`かつ`success_nodes == total_nodes`を確認してから投入する。
- Step別commitは`974158d`、`6f8429b`、`e8e25b`、`d29c2b`、`bf2fbfa`、`a26386c`、`2a240ad`、`68cc929`、`ecd2e59`、`871c35a`、`eb13d14`。
- version更新、tag、release、sibling repositoryの変更は行っていない。
