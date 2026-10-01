# Todo: 新4台のSMB読込み・計算・結果返送を実機確認する

## 状態

- 2026-09-30作成。同日、先生から「もち，強化Cでいこうよ」と開始承認を受けた。
  Step 1完了・push済み (`1ffa1a0`)。Step 2初回はREXへ1件投入後、結果返送の60秒期限超過で停止した。
  2026-10-01にREX再試験・JESSE・FIVESのStep 2–4が成功。Step 5–6は未着手。
  実機投入は合計4件（初回timeout・正常3件）、正常完了確認はREX/JESSE/FIVESの3台。
- 2026-10-01、先生からREX側のアクセス許可ダイアログでOKを押したとの報告と「再テストしてみて」の指示を受けた。
  この指示ではStep 2のREX再試験1件だけを実施し、commit `3bfeb59`でpushした。
- 同日、先生から「ほかのもネットワークディレクトリへのアクセスのパーミッション開いてきたよ」と報告があった。
  残り3台も許可済みという前提で、承認済みの強化Cに沿ってStep 3から再開する。Stepの追加・順序変更はしない。
- 前の設定追加は全3 Step完了（HEAD `ab16a3752db85be363db97eb8a33bf511af53fd4`）。
  完了Todoを[historyへ退避](history/TODO_syncopade_add_four_nodes.md)した。
- 先生の報告: 新4台がconductor上でIDLE、SMB接続済み、共有パスは全台`/Volumes/syncopade_nfs`で一致。
- 先生から追加確認: いつものconductorはMSE-06上、現在は通常計算を休止中。今回の通信はlan12を使う。
- 2026-09-30 18:10 JST、読み取り専用の`LIST`と`RUNTIME`でMSE-06の
  `192.168.12.4:9004`への接続と新4台の`idle / ready=true`を確認した。
  計算投入・再起動・cache clear・共有ファイル変更は行っていない。詳細は下の事前確認記録。
- ローカルから共有上の既存`syncopadeBasicTestScript.jl`を読み取り、リポジトリ内の正本との完全一致を確認した。
  SHA-256: `06c7c238922e62ff14f5e6b692e1bf6e90f4bd93276b0993c584a455f96b6c8d`。
  コピー・書換えは不要。これは他4台からの読込み成功の証拠ではなく、各台で後から検証する。
- 進行方式は今回の明示承認に基づく強化C。単純な灯子のミスだけ自律修正し、前提・対象変更なら止まる。
  各StepはPhase 1→2→3→4を順に記録し、完了Stepごとに対象だけcommit/pushする。
- 既存差分は`logs/conductor_events.csv`の4行追加のみ。試験前SHA-256は
  `20f0129709ac36e64ec0191878ee18be2cc247104e74a5b54d46aedc305dbef0`。
  既存logを手で変更・削除・復元・commitしない。実サービスによる試験時の自然な追記は別途記録して保持する。

## 対象と確認範囲

| 試験順 | 名前 | lan12 | lan100 |
|---|---|---|---|
| 1 | REX | 192.168.12.18:8018 | 192.168.100.104:8104 |
| 2 | JESSE | 192.168.12.17:8017 | 192.168.100.106:8106 |
| 3 | FIVES | 192.168.12.16:8016 | 192.168.100.105:8105 |
| 4 | KIX | 192.168.12.15:8015 | 192.168.100.107:8107 |

- conductorはMSE-06（設定上の表記は`MSE-6`）の`192.168.12.4:9004`。
  先生の指定と実応答に基づき、今回の宛先はlan12に限定する。lan100へは接続しない。
  このPCのlan12アドレスは`192.168.12.2`。結果返送と待受けに明示して使い、portは試験入口で確定する。
  2026-10-01の再試験でREXからの結果返送を確認済み。他3台からの返送は未検証。
- 通常の新規投入が止まり、既存の待機・実行中・成否不明の仕事がないことを確認してから実機試験を始める。
  IDLE一覧だけをqueueが空であることの証拠にしない。
- 計算の入力は`[2,3,5]`と`[7,11,13]`、期待値は`30030.0`。
  呼出し元は共有上の絶対パス`/Volumes/syncopade_nfs/syncopadeBasicTestScript.jl`、
  moduleは`syncopadeBasicTestScript`、functionは`test`。外部packageは不要。
- 新4台には各1件を直接指定して逐次投入し、最後にconductor経由で1件。通常成功時は合計5件だけ。
  短い仕事をconductorへ4件投げる方法では、同じnodeが繰り返し選ばれ得るので各台確認の代用にしない。
- 最後のconductor試験では既存profileの配送候補を変更しない。通常の優先順を使い、実際の割当先を記録する。
  既存nodeへ割り当てられる可能性もあり、その結果を新4台の直接試験の代用にはしない。
- 本計算用package、SMB書込み性能、負荷性能、4台同時実行、他方LANでの通信は今回の完了範囲に含めない。
- conductor/server本体・node設定・共有ファイル・他リポジトリを変更しない。
  server再起動・executor交換・cache clear・version/tag更新も行わない。
  コード更新や環境変更が必要になった場合はTodo全体を見直し、必要な配備・cache更新を別途確認する。

## 共通の合否判定と記録

- 試験前: 対象endpoint、時刻、`listener_id`、`server_id`、ready/idleを記録する。
- 受信待受けを先に開き、明示した結果返送IPと実際の待受けIPを一致させてから1件だけ送る。
  2系統LANの自動選択に任せず、IPとportを記録する。
- 成功条件: 受付成功、返送されたjob IDが受付応答と一致、`ok=true`、結果文字列が`30030.0`、
  終了後に同じ起動IDのままidle/readyへ復帰。conductor経由ではtask IDと正常終端も一致すること。
- 短い計算なので途中のbusyを監視画面で捕まえることは必須にしない。受付応答・結果・終端を証拠にする。
- 通信・結果待ちにはこの軽い試験だけの有限期限を設ける。実計算の強制停止機能は追加しない。
  timeoutは「未実行」と扱わず、受理・完了状況を照会してから止まる。盲目的な再投入はしない。
- 正常終了・異常・timeoutのいずれでも、自分が開いたcallback socket・待機Taskを回収する。
  稼働中サービスや計算子をkillしない。
- 結果は本Todoと今回専用のlogへ残し、既存conductor CSVには手を加えない。

## 開始前の読み取り専用確認記録

- 確認時刻: 2026-09-30 18:10 JST。各通信の待ち期限は5秒。確認コマンドはexit 0。
- conductor `192.168.12.4:9004`へ`LIST`を1回送り、checksumが正しい応答を確認した。
  idle一覧は11 endpointで、下記の新4台をすべて含んでいた。他5台の状態はこの一覧だけでは判断しない。
  この応答は待ち行列が空であることの証明ではなく、通常計算の休止は先生の報告に基づく。
- 新4台へ`RUNTIME`を各1回だけ照会した。全台`idle / ready=true`、Julia `1.12.7`、Syncopade `0.1.5`。
  以下はこの時刻の起動IDであり、各実機試験の直前にも取り直す。

| ノード | lan12 endpoint | listener_id | server_id |
|---|---|---|---|
| REX | 192.168.12.18:8018 | f5b27e1e-47a7-4c18-a07c-3aab19537378 | b376e030-edeb-4c1c-b504-8ad552f62b43 |
| JESSE | 192.168.12.17:8017 | 82f57753-e61c-4092-bfff-72dbabb9b0f9 | 1f5a80da-58f5-4994-bc34-ae4a4707189c |
| FIVES | 192.168.12.16:8016 | 13165829-b6f1-4486-bb84-a4d99c1f0447 | 684321fb-3507-4163-ab78-518abf99a04a |
| KIX | 192.168.12.15:8015 | baf3c050-15b1-4bbf-9dd0-3b8fd6984bcd | c6ac16c9-91ba-462d-b7a5-43e1877ed492 |

- この確認では結果返送用socketを開かず、計算も投入していない。Stepの完了扱いにはしない。

## Step 1: 試験入口を準備し、実行先を確定する

- **目的:** 実機への投入前に、正しい宛先・結果照合・後始末を保証できる試験手順を用意する。
- **対象ファイル:** `test/integration_four_node_readiness.jl`（新規の明示起動用driver）、
  `test/unit_four_node_readiness_driver.jl`（新規のローカル確認）、本Todo。
- **方針:** 既存client APIを用い、1回の起動で1 endpoint／1 taskだけ試す小さなdriverにする。
  directとconductor経由を区別し、実機の処理を`include`時や通常の回帰suiteから自動開始させない。
- **関数仕様案:** 入力はmode・対象IP/port・callback IP/port・共有source絶対パス・試験用timeout。
  出力は宛先・起動ID・job/task ID・期待値照合・復帰状態の記録と成功/失敗のexit code。
  副作用は指定task 1件と自分のcallback待受けだけ。実機モードの実行はStep 2以降に限定する。
- **完了条件:** 正常結果、ERROR返送、違うID/値、timeoutの扱いと後始末をローカルで検査済み。
  conductorのIP/port・profileとcallback経路が記録され、先生と投入停止を確認できている。
- **検証方法:** 共有と正本のhash確認、構文/単独ローカル試験、diff check。
  実機の事前確認は承認後の読み取り専用STATUS/RUNTIME/LISTと、conductorの状態表示・記録の確認まで。
  このStepで実機へ計算は投入しない。
- [x] Phase 1 — 方針・前提を確認
- [x] Phase 2 — 入出力・合否・後始末仕様を確定
- [x] Phase 3 — 試験driverとローカル確認を実装
- [x] Phase 4 — ローカル検証・接続先/投入停止の確認・記録・commit/push (`1ffa1a0`)

### Step 1 / Phase 1 記録

- server/client/conductorの通信形式をソースで照合した。既存clientのchecksum・応答parserと
  有限期限付き`management_request`を利用し、試験専用ファイル内で1回限りの受信と照合を行う。
  無期限待ちの既存submit関数をそのまま使わず、同じpayloadを既存の有限期限付き通信関数で送る。
- 実機入力は共有上の既存関数と固定した2ベクトルのみ。起動引数がなければ通信せず、includeも定義だけとする。
- conductorの割当先はcallback接続の送信元IPから特定し、LIST内の一意なserver endpointと対応させる。
  task/job IDをconductorの`TASK_STATUS`完了記録と照合する。遠隔CSVへの書込みや新しい照会APIは追加しない。
  試験logには受付・callback・終端の各記録を残す。通常計算休止は先生の報告を前提とし、LISTをqueue空の証明にはしない。

### Step 1 / Phase 2 記録

- `run_probe(mode, target_ip, target_port, callback_ip, callback_port, source, timeout; io)`:
  modeはdirect/conductor、portは対象1–65535・callback 0–65535（0はOSが空きを選択）、
  IPは明示IPv4、sourceは絶対パスで既存正本とSHA-256一致、timeoutは正の有限秒数とする。
  戻り値はjob/task ID・実worker endpoint・callback port・結果。異常は例外、CLIではexit 1。
  副作用は1件だけの投入・一時待受け・指定ioへの監査記録。再送・再起動・cache変更・共有書込みはしない。
- `receive_once(listener, timeout)`: 1接続の送信元IPとchecksum付き1行を取得する。
  受付応答より先にcallbackが来ても、先に開いたlisten socketの待ち行列で受けられる。
  有限期限でaccept/readを打ち切り、自分の接続とTimerを必ず閉じる。独立した受信Taskは作らない。
- `checked_payload(row)` / `validate_result(mode, accepted_id, message)`:
  既存parserを利用し、checksum、protocol、受付ID、ok、厳密な結果文字列`30030.0`を検査する。
- `read_task_status(...)` / `wait_terminal(...)`: 有限期限付きTASK_STATUS照会でtask/job IDと
  `terminal / WORKER_DONE_OK`を確認する。callbackの送信元IPをLISTのendpointと対応させた記録と照合する。
- `wait_idle(...)`: 試験前後でlistener/server IDが同一、ready/idleへ復帰したことを有限期限内に確認する。
  conductor modeでは投入前LISTの候補のRUNTIMEを読み、実際に選ばれたworkerの前後IDを照合する。
- 送信後の失敗は結果不明として記録し、既知task IDのTASK_STATUSと対象RUNTIMEを読み取り照会して止まる。
  受理を否定できない場合は「未実行」と断定しない。試験の受付待ちは最大5秒、結果・終端・idle待ちは各60秒を基本にする。
- 終了時にはcallback待受けを閉じ、同一IP/portを再度bindできることも確認する。
  ローカル検証は127.0.0.1上の模擬応答だけを使い、正常・ERROR・ID/値違い・checksum違い・待ち期限超過・後始末を検査する。
- CLIは上記7引数に今回専用logのパスを加えた8引数。既存logがあれば上書きせず拒否する。

### Step 1 / Phase 3 記録

- `test/integration_four_node_readiness.jl`を追加。includeは定義だけ、明示起動で1件だけ通信する。
  既存APIのchecksum/parser/有限期限付き要求を使用し、socket・Timerの終了とport再利用を検査する。
- `test/unit_four_node_readiness_driver.jl`を追加。127.0.0.1上の模擬相手で正常と異常を検査する。
  稼働中のconductor/server、node設定、共有source、通常suiteの自動起動対象は変更していない。

### Step 1 / Phase 4 検証記録

- 初回ローカル検証は灯子の模擬応答内の`continue`が非同期関数の外側のloopを参照する構文ミスで開始できなかった。
  当該模擬応答を終了する`return nothing`へ修正した。実機への通信はなし。強化Cの単純ミス修正範囲として再検証する。
- 最終ローカル検証: `julia --startup-file=no --project=. test/unit_four_node_readiness_driver.jl`、251/251成功、exit 0。
  CLIのlog生成・既存log上書き拒否と、指定LAN以外への接続拒否も確認した。
- 関連既存テスト: `unit_client_protocol.jl` 63/63、`unit_result_protocol.jl` 43/43、
  `unit_server_management_protocol.jl` 30/30。全てexit 0。製品コード無変更のため今回は関連範囲を検証し、全suiteの再実行はしていない。
- 読み取り専用事前確認を再実施し、MSE-06のLISTに新4台が含まれ、全4台idle/ready・開始前と同じ起動IDを確認した。
- 共有fixtureと正本のSHA-256一致、既存conductor CSVのSHA-256不変を確認した。
  サーバ側実装はcache照会前にsourceの存在を調べる。今回の試験では関数cacheを消さず、cache未使用や毎回のファイル再読込みまでは保証しない。
- Todo開始前の整理はcommit `44e39c5`でpush済み。今回追加ファイルを含むdiffを検査後、Step 1としてcommit/pushする。

## Step 2: REXへ直接1件送る

- **目的:** まず1台でSMB上の関数呼出しから結果返送までを確認する。
- **対象ファイル:** 本Todo、今回専用の試験log。Step 1のdriverを使う。
- **完了条件:** REXの指定endpointで共通の合否判定をすべて満たす。
- **検証方法:** 起動ID、受付job ID、結果`30030.0`、返送照合、idle復帰、callback後始末を記録する。
- [x] Phase 1 — REXの宛先・事前状態を確認
- [x] Phase 2 — 1件の入力と判定条件を固定
- [x] Phase 3 — 1件だけ投入
- [x] Phase 4 — 結果/復帰/後始末確認・記録・commit/push（2026-10-01再試験で成功）

### Step 2 / Phase 1 記録

- REX `192.168.12.18:8018`を明示指定する。直前の読み取り確認はidle/readyで起動IDも不変。
  検証済みdriverをそのまま使用し、投入直前のRUNTIMEでも再確認する。通常計算休止の前提は継続。

### Step 2 / Phase 2 記録

- 入力: direct、REXの上記endpoint、callback `192.168.12.2:0`（実portをlogへ記録）、
  共有source絶対パス、既定の2ベクトル、待ち期限60秒（受付通信は5秒）。
- 出力・合否: job ID一致、送信元IPがREX、`30030.0`、同一起動IDのidle復帰、callback port再利用。
  副作用は試験1件と自分の待受けのみ。logは`logs/four_node_readiness_20260930_step2_rex.log`。

### Step 2 / Phase 3 記録

- 2026-09-30 18:18:26 JST、REXへ1件だけ直接投入した。
  `OK|STARTED|28067c82-be94-4ffb-9421-a59ec9a31c74`を受信。callbackは`192.168.12.2:61170`。
  受付までは成功、結果・復帰はPhase 4で確認する。再投入はしていない。

### Step 2 / Phase 4 記録 — 不合格・停止

- **症状:** 18:19:26 JSTにcallback待ち60秒を超過、試験processはexit 1。
  結果接続自体を受け付けられなかったため、値・job ID照合・idle復帰は確認できていない。
- **根拠:** [今回の生log](logs/four_node_readiness_20260930_step2_rex.log)に受付job IDと失敗を記録。
  期限直後の読み取り照会はREX `busy / ready=true`、listener/server ID・PIDは投入前と同じ。
  受付拒否やserver停止と同一視しない。`ready=true`は次の計算を受けられる意味ではなく、busyは継続していた。
- **原因候補:** sourceの読込み、計算子の処理、結果返送などのどこで待っているかは未確定。
  現在のRUNTIME応答には実行位置がなく、この結果だけでSMBやfirewallの不具合とは断定しない。
- **確認方法:** REX側のrun_server出力で、該当job IDの受理後から現在までの出力を確認する。
  source読込みエラー、fixtureの開始/計算結果出力、callback接続エラーの有無を順に照合する。
- **修正案:** 原因未確定のため未決定。試験期限の延長・再投入・cache clear・再起動で押し切らない。
  続行に環境変更や調査手順の変更が必要なら、先生とTodo全体を見直す。
- **検証方法:** 原因を絞った後に必要な修正と再試験条件を相互確認する。現時点ではStep 2を完了扱いしない。
- **後始末:** 自分のcallback待受けを閉じ、`192.168.12.2:61170`の再bind成功を確認した。
  自分の試験processは終了済み。REX側の計算・executor・listenerには終了指示を送っていない。
  遅れて返送される結果を受け取る待受けはもうないため、実行結果は不明のまま扱う。
- 既存`logs/conductor_events.csv`のSHA-256は開始前と同じ。今回のTodoと専用logだけを停止記録としてcommit/pushする。

### Step 2 再試験 / Phase 1 記録 — 2026-10-01

- 前回停止後、先生から「ターミナルのネットワーク関連アクセス許可ダイアログが出ていた」「OKを押した」と報告があった。
  ダイアログの正確な文面と遠隔側の処理位置は未確認。許可待ちは原因候補であり、まだ確定扱いにはしない。
- 2026-10-01 09:02 JSTの読み取り照会では、REXは前回と同じlistener/server ID・PIDでidle/readyへ戻っていた。
  前回jobの結果は未受信のまま保存し、今回の成功結果で前回の記録を上書きしない。
- 方針は既存driver・同じ共有source・同じ入力でREXへ1件だけ再投入。投入直前のRUNTIMEでもidle/readyを確認する。
  共有sourceと正本のSHA-256は引き続き一致。製品コード・試験driver・期限・共有ファイル・設定は変更しない。

### Step 2 再試験 / Phase 2 記録 — 2026-10-01

- 入力: direct、`192.168.12.18:8018`、callback `192.168.12.2:0`、
  `/Volumes/syncopade_nfs/syncopadeBasicTestScript.jl:syncopadeBasicTestScript:test`、`[2,3,5]`と`[7,11,13]`。
  受付5秒・結果/復帰各60秒を維持する。
- 合否は受付job IDとcallbackの一致、送信元REX、`ok=true / 30030.0`、同一起動IDのidle復帰、callbackの後始末。
- 副作用は先生が明示した再試験1件と自分の待受けのみ。
  新規log `logs/four_node_readiness_20261001_step2_rex_retry1.log`へ記録し、前回logを保持する。

### Step 2 再試験 / Phase 3 記録 — 2026-10-01

- 09:05:19 JST、上記の固定入力をREXへ1件だけ送った。
  `OK|STARTED|eb0ce938-3a7a-4029-ae10-d91c7bf25a7a`を受信。今回のcallbackは`192.168.12.2:50315`。
  受付前RUNTIMEは前回と同じlistener/server ID・PIDでidle/ready。追加再送はしていない。

### Step 2 再試験 / Phase 4 記録 — 成功

- [今回の生log](logs/four_node_readiness_20261001_step2_rex_retry1.log)に全経路を記録。試験processはexit 0。
  09:05:19.248に受付、09:05:19.372にREX `192.168.12.18`から
  `RESULT|eb0ce938-3a7a-4029-ae10-d91c7bf25a7a|OK|30030.0|5e`を受信した。
- checksum・job ID・成功状態・期待値が一致。09:05:19.374に前後で同じlistener/server ID・PIDのidle/ready復帰を確認した。
  09:05:19.375にcallback `192.168.12.2:50315`を閉じ、同一portの再bind成功を確認した。
- logを独立に再読込して、受付/返送が各1件、checksum・job ID・積の期待値・起動ID・後始末を11項目で再照合し、11/11成功。
- 製品コード・試験driver・共有source・server起動IDを変えず、先生の許可操作後の再試験が成功した。
  初回が許可待ちだったという説明と整合するが、ダイアログの種類や初回jobの計算結果までは確定しない。
  cacheを維持した試験なので、今回新たに共有ファイルの本文を読み直した証拠とは扱わない。
- 前回log・既存conductor CSVは無変更。共有fixtureと正本のSHA-256も不変。
  今回のTodoと新規logだけをStep 2完了としてcommit/pushする。他3台・conductor経由は未試験のまま。

## Step 3: JESSEへ直接1件送る

- **目的:** REXの成功を一般化せず、JESSE自身の環境と返送経路を確認する。
- **対象ファイル:** 本Todo、今回専用の試験log。Step 1のdriverを使う。
- **完了条件:** JESSEの指定endpointで共通の合否判定をすべて満たす。
- **検証方法:** REXと同じ入力・判定を使い、JESSE固有の起動ID・job ID・結果・idle復帰を記録する。
- [x] Phase 1 — JESSEの宛先・事前状態を確認
- [x] Phase 2 — 1件の入力と判定条件を固定
- [x] Phase 3 — 1件だけ投入
- [x] Phase 4 — 結果/復帰/後始末確認・記録・commit/push

### Step 3 / Phase 1 記録 — 2026-10-01

- JESSE `192.168.12.17:8017`を直接指定する。09:25 JSTの読み取り照会でidle/readyを確認した。
  callback側アドレス`192.168.12.2`も確認済み。共有sourceと正本のhash一致、既存conductor CSVのhash不変。
- 先生の許可操作を環境側の準備完了として受け取り、製品・driver・共有ファイルは変更せず、既存driverで1件だけ試す。
  投入直前にもRUNTIMEを取り直し、REXの成功をJESSEの成功として扱わない。

### Step 3 / Phase 2 記録

- 入力はdirect、JESSEの上記endpoint、callback `192.168.12.2:0`、共有上の既存basic fixture、
  `[2,3,5]`と`[7,11,13]`。受付5秒・結果/復帰各60秒を維持する。
- 受付/返送job ID、送信元JESSE、成功値`30030.0`、同一起動IDのidle復帰、callback後始末を全て必須とする。
  副作用は1件の計算と一時待受けのみ。専用logは`logs/four_node_readiness_20261001_step3_jesse.log`。

### Step 3 / Phase 3 記録

- 09:25:32 JST、JESSEへ指定した入力を1件だけ送信。
  受付job IDは`bb29a8c4-9338-4f9f-bb95-a56688a1a820`、callbackは`192.168.12.2:50518`。
  入力変更・再送・再起動・cache clearは行っていない。

### Step 3 / Phase 4 記録 — 成功

- [専用log](logs/four_node_readiness_20261001_step3_jesse.log): exit 0。
  09:25:33.079にJESSEから同じjob IDの`OK / 30030.0`を受信し、checksumを検証した。
  同じlistener/server ID・PIDでidle/ready復帰、callback port再bind成功を確認した。
- log再読込の独立照合も12/12成功。実投入は1件のみ。Todoと専用logだけをStep 3完了としてcommit/pushする。

## Step 4: FIVESへ直接1件送る

- **目的:** FIVES自身の環境と返送経路を確認する。
- **対象ファイル:** 本Todo、今回専用の試験log。Step 1のdriverを使う。
- **完了条件:** FIVESの指定endpointで共通の合否判定をすべて満たす。
- **検証方法:** 同じ入力・判定を使い、FIVES固有の起動ID・job ID・結果・idle復帰を記録する。
- [x] Phase 1 — FIVESの宛先・事前状態を確認
- [x] Phase 2 — 1件の入力と判定条件を固定
- [x] Phase 3 — 1件だけ投入
- [x] Phase 4 — 結果/復帰/後始末確認・記録・commit/push

### Step 4 / Phase 1 記録 — 2026-10-01

- Step 3をcommit `40a1ded`でpush済み。FIVES `192.168.12.16:8016`の09:26 JSTのRUNTIMEはidle/ready。
  先生のネットワークディレクトリ許可済みという報告を前提に、既存driverでこの1台だけ試す。
  製品・driver・共有source・LANを変更せず、投入直前にも状態を取り直す。

### Step 4 / Phase 2 記録

- 入力はdirect、FIVESの上記endpoint、callback `192.168.12.2:0`、共有上の既存basic fixture、
  `[2,3,5]`と`[7,11,13]`。受付5秒・結果/復帰各60秒。
- 合否はjob ID一致、送信元FIVES、成功値`30030.0`、同一起動IDのidle復帰、callback後始末。
  副作用は1件の計算と一時待受けのみ。logは`logs/four_node_readiness_20261001_step4_fives.log`。

### Step 4 / Phase 3 記録

- 09:26:42 JST、FIVESへ指定入力を1件だけ送信し、job ID `4acb18f4-5bb9-475f-b369-ff783440fddc`を受け付けた。
  callbackは`192.168.12.2:50549`。再送・設定変更は行っていない。

### Step 4 / Phase 4 記録 — 成功

- [専用log](logs/four_node_readiness_20261001_step4_fives.log): exit 0。
  09:26:42.783にFIVESから受付と同じjob IDの`OK / 30030.0`を受信。
  checksum一致、同じlistener/server ID・PIDでidle/ready復帰、callback port再bind成功を確認した。
- 独立したlog再照合も12/12成功。Todoと専用logだけをStep 4完了としてcommit/pushする。

## Step 5: KIXへ直接1件送る

- **目的:** KIX自身の環境と返送経路を確認し、直接確認を4/4台にする。
- **対象ファイル:** 本Todo、今回専用の試験log。Step 1のdriverを使う。
- **完了条件:** KIXの共通判定が成功し、新4台それぞれの正常結果が揃う。
- **検証方法:** 同じ入力・判定を使い、KIX固有の起動ID・job ID・結果・idle復帰と4台分の記録を確認する。
- [ ] Phase 1 — KIXの宛先・事前状態を確認
- [ ] Phase 2 — 1件の入力と判定条件を固定
- [ ] Phase 3 — 1件だけ投入
- [ ] Phase 4 — 結果/復帰/後始末確認・4台分集計・記録・commit/push

## Step 6: conductor経由で1件だけ確認する

- **目的:** 直接通信とは別に、通常の受付・配送・結果通知・終端管理の経路を確認する。
- **対象ファイル:** 本Todo、今回専用の試験log。Step 1のdriverを使い、conductorの記録は読み取るだけ。
- **完了条件:** task IDとjob IDが一致する正常結果`30030.0`、conductorの正常終端、
  実際に割り当てたworkerとそのidle復帰を確認できる。4台同時利用の証拠とは扱わない。
- **検証方法:** 同じ共有source・入力で1件SUBMITし、callback、TASK_STATUS、対応する配送/完了記録を照合する。
  終了後に今回のcallback待受けが残らず、全5件の成否と未検証範囲が記録されていることを確認する。
- [ ] Phase 1 — conductorの宛先・queue/worker状態を確認
- [ ] Phase 2 — 1件の入力・task/job照合・正常終端条件を固定
- [ ] Phase 3 — 1件だけ投入
- [ ] Phase 4 — 結果/終端/割当先/後始末確認・総括・commit/push

## 停止条件

- 宛先や運用LAN、投入停止が確認できない場合は、計算を送る前に止まる。
- 試験先のBUSY/down、共有ファイル不一致、ERROR返送、ID/値不一致、timeoutなどは原因と状態を記録して止まる。
- 強化Cを承認された場合でも、灯子の単純なdriverの誤字などだけを自律修正する。
  実機の設定変更・共有ファイル更新・再起動・Todo変更が必要なら先生に方針を戻す。
- 本Todoの相互確認・開始指示前に、実機へ試験taskを送らない。
