# Syncopade BUSY配送・終端通知 修正 Todo

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

## Step 1: node状態と割当ての原子的な遷移を定義する — 未着手

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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 2: 古いSTATUS応答を適用しない — 未着手

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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 3: node選択と配送予約を一体化する — 未着手

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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 4: DONEをtask IDとjob IDで照合する — 未着手

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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 5: worker受付応答を種類別に解析する — 未着手

### 目的

`OK|STARTED|job_id`、`ERROR|BUSY`、protocol異常、通信失敗、受付応答timeoutを同じ一般例外へ潰さず、conductorが判断できる形に分ける。

### 対象ファイル

- `syncopadeClient.jl`
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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 6: BUSYでtaskを失わず、空いた後に1回だけ配送する — 未着手

### 目的

workerのBUSY拒否を故障再試行から外し、taskとnodeを正しい状態へ戻して次の空き確認を待つ。

### 対象ファイル

- `syncopadeConductor.jl`
- `test/reproduction_conductor_busy_drop.jl`（修正後回帰試験へ変更・改名候補）
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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 7: conductor taskの寿命と状態照会を実装する — 未着手

### 目的

受付済みtaskをqueueから消えた後もtask IDで追跡し、callbackに失敗しても親が状態を照会できるようにする。

### 対象ファイル

- `syncopadeConductor.jl`
- `syncopadeClient.jl`
- `test/unit_conductor_task_lifecycle.jl`（新規候補）
- `test/unit_client_protocol.jl`
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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 8: worker受付期限と受付成否不明を別々に終端する — 未着手

### 目的

BUSYまたはidle nodeなしでworker受付前のtaskを無期限に待たせず、同時に受付応答timeout後の危険な再配送を防ぐ。worker受付後の計算実行時間には制限を加えない。

### 対象ファイル

- `syncopadeConductor.jl`
- `syncopadeClient.jl`
- `test/regression_conductor_queue_deadline.jl`（新規候補）
- `test/regression_conductor_dispatch_timeout.jl`（新規候補）
- `test/fixtures/conductor_controlled_worker.jl`
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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 9: task ID付き結果protocolを追加する — 未着手

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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 10: conductor打切りを親へ一度だけ通知する — 未着手

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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 11: 修正後回帰試験を統合しlan100で確認する — 未着手

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

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

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
