# Todo: 受付を維持した計算用Juliaの分離・再起動

## 状態

- 2026-09-16作成、同日先生が18 Stepを承認し「強化C」で開始を指示。全Phaseを順番に記録する。
- 2026-09-16改訂: 先生の指示でconductor経由の全node一斉再起動を追加。
  単体再起動→一斉操作管理→並行送信→公開操作→統合検証の順に全体を18 Stepへ組み直した。
- このTodoの作成・確認はStep 1にも、そのPhase 1にも含めない。
- 進行方式: 強化C。検証済みStepごとにcommit/pushし、前提変更が必要なら停止する。
- 現在: Step 1–16は検証・commit/push済み（`3f7884f`まで）。Step 17のSIGINT試験失敗で一度停止。
  先生の「直す方針あるなら直して進めて」により、終了入口・子への割込み伝搬・試験後始末の見直しと再開を承認。
  Step 17は改訂後の検証に合格。対象差分をcommit/push後、Step 18へ進む。version/tag・本番LAN操作は引き続き対象外。
- 作成時HEAD: `ce9d69c2ba06d701a8abc9957d8bf481ade7e4d2`、`master`、`v0.1.4`。
- 既存の完了Todoはすべて`history/`にあるため、今回の作成時に移動するTodoはない。
- 作成時の既存差分: `logs/conductor_events.csv`の4行追加。
  SHA-256: `20f0129709ac36e64ec0191878ee18be2cc247104e74a5b54d46aedc305dbef0`。

## 目的と根拠

先生が計算コードを更新したとき、受付のIP・portと受付Juliaを維持しながら、
読み込み済みpackageを持つ計算用Juliaだけを終了・再起動できるようにする。
同じ計算用Juliaを複数taskで再利用し、明示された再起動時だけ交換する。
単一nodeへの指定に加え、conductorへの1回の指示で設定された全nodeの計算Juliaへ
並行して再起動を指示し、node別の結果をまとめて確認できるようにする。

現行コードでは次の経路になっている。

- `scripts/run_server.jl`が`syncopadeServer.jl`の`main()`を呼ぶ。
- 同一Julia内の受付処理が`call_func`でtaskを実行する。
- `call_func`は`(script_path, module_name, function_name)`をキーに関数を保持する。
- `clear_function_cache!`はその辞書とLRU一覧を空にするだけである。
- 再度`include`されるtaskから同じUUIDのpackageを読み込んでも、
  そのJulia内に既にロードされているpackage moduleが再利用される。

会話内の調査では、taskファイルの変更はcache clear後に反映された一方、
依存packageの変更はcache clear後も旧値のまま、新規Juliaでは新値になることを確認した。
この試験は一時コードによる観測で、リポジトリの回帰試験としては未保存。
Step 1でassertion付きの再現試験にする。実運用の全事例の原因まで確定したとは扱わない。

理論上の根拠は[Julia公式 Code Loading](https://docs.julialang.org/en/v1/manual/code-loading/)。
`include`による再評価と、同じpackage identityへの`using/import`による再利用を区別する。
`Base.invokelatest`はファイルやpackageを再ロードする操作ではない。

## 今回の構成案

```text
client / conductor
        |
        | 既存の公開IP・port
        v
受付Julia  listener_id=L1
        |
        | 同じPC内だけの専用通信
        v
計算Julia  server_id=S1   --明示的な再起動-->   server_id=S2
```

### 役割とID

| 対象 | 所有するもの | IDの寿命 |
|---|---|---|
| 受付Julia | 公開socket、受付状態、job予約、子process監視、callback・DONE送信 | `listener_id`: 受付起動ごとにUUIDを発行 |
| 計算Julia | taskのinclude、関数cache、package、実計算 | `server_id`: 計算Julia起動ごとにUUIDを発行 |
| conductor | 既存のqueue、task ID、node割当て、一斉再起動の対象と結果 | 既存taskの契約を維持。一斉操作には照会用`operation_id`を付ける |

- 現行serverには、この意味の`server_id`はまだ存在しない。2つの起動IDを新設する。
- nodeは既存のIP・port・設定名で指定する。新しい固定`node_id`は追加しない。
- `task_id`、`job_id`は既存の意味を保つ。起動IDをそれらの代用にしない。
- 起動IDは専用通信、状態照会、再起動要求、監査記録で照合する。
- 受付側の記録には子の起動・終了・交換・失敗と、listener/server/job IDの対応を残す。
  既存conductor CSVの形式は維持し、先生の既存logへ新しい列を混在させない。
- 既存conductor内の状態更新用`generation`は維持する。
  これと起動IDは用途が異なるため、今回まとめて置き換えない。

### 簡潔にするための初版の範囲

- **1受付につき計算Juliaは1本、同時実行taskは1件。**
- 再起動操作は宛先IP・portを明示した単一node指定と、conductor経由の全node一斉指示を用意する。
  それぞれ公開client APIとCLIを用意し、単体操作を作ってから一斉操作に接続する。
- 再起動はbatchの切れ目で行う。投入元は投入を止め、先行taskの終端を確認してから要求する。
- 計算中・予約中・結果通知処理中の再起動はBUSYで拒否する。終了待ち予約は作らない。
- 受付が再起動を受理した後は、新規taskをBUSYで拒否する。
  conductor経由のtaskは既存のBUSY待機処理で保持される。
- queue内のtaskとコード版の対応付け、複数版の同居は対象外。
  単体再起動中にqueueへ入ったtaskは、その後の計算Juliaで実行され得る。
  全node一斉指示は以下の条件で投入・配送と排他にする。
- 起動IDの変化はprocess交換を示す。アプリケーションの指定revisionをロードした保証にはしない。
  Project/Manifestの配布・固定は従来どおり利用側の責務とする。

### 全nodeへの一斉指示

- 対象はconductorの選択中profileに設定された全endpointを、要求受理時に重複除去して固定する。
  現行`LIST`はidle nodeだけを返すため、対象決定には使わない。
  busy・down・未対応nodeを対象から黙って除かない。対象0件は成功としない。
- 全台同時刻の切替は保証しない。1回の要求から各nodeへ並行して指示し、各nodeが独立して交換する。
  成功したnodeを、別nodeの失敗に合わせて元へ戻す処理は追加しない。
- conductorはqueueと予約・実行中・受付成否不明の割当てが空であることを確認し、
  確認と一斉操作の開始を投入・配送に対して原子的に行う。空でなければ要求全体をBUSYで拒否し、
  再起動指示を1件も送らない。実行中taskを待つ予約や強制終了は行わない。
- 操作中の新規SUBMITは明示的な未受付エラーを返し、queueへ追加しない。
  monitorの状態照会と既存taskの状態照会は継続し、配送は停止する。
  他の一斉再起動と`CACHE_CLEAR_ALL`の変更操作も同時に開始しない。
- nodeごとに起動IDを照会し、期待`listener_id/server_id`付きで再起動を要求する。
  conductorが把握していない直接投入や別conductorの操作と競合した場合も、
  各受付のbusy判定とID照合で拒否する。全nodeを予約する分散transactionは作らない。
- node別結果は成功、BUSY拒否、ID不一致、接続/旧protocolの失敗、起動失敗、成否不明を区別する。
  結果にはendpoint、名前、旧/新起動ID、確認できた状態、理由を含める。
  `success_nodes`と`failed_nodes`を返し、BUSY拒否・成否不明も成功以外として後者に含める。
  常に`total_nodes = success_nodes + failed_nodes = node別結果数`を満たす。
- 全体成功は対象が1件以上で、全対象の受付ID不変・計算ID変更・新子readyを確認できた場合だけとする。
  一部失敗時は部分成功として返し、成功したnodeも含む内訳を残す。失敗nodeを自動再実行しない。
- callerが生成する`operation_id`で操作を登録し、同じIDの再送では再起動を重ねず現在の記録を返す。
  これは一斉要求の照会番号であり、計算processの世代やコード版を管理するIDではない。
  clientの接続断後もconductorは開始済み操作を収集し、操作IDによる状態照会で結果を回収できる。
  保持期間はconductorの存続中とし、conductor再起動後は「記録不明」と返して自動再送しない。
- 接続・照会・再起動待ちにはnode別の期限を設け、停止node1台で他nodeの処理を止めない。
  期限切れの通信とtaskを回収し、要求送信後のtimeoutは「未実行」ではなく成否不明とする。
  操作記録を確定した後の遅延応答で、後続操作や別jobの状態を上書きしない。
- 全対象の結果が確定したら、一斉操作中の投入・配送制限を解除する。
  成否不明nodeは旧idle観測だけで再利用せず、現在の起動IDとreadyを照会して整合するまで配送対象外とする。
  再起動前と同じserver IDのidleだけでは除外を解除しない。要求の未受理が確定するか、
  同じlistener IDの新しいserver IDとreadyを確認してから解除する。
  一部成功は全体の更新完了を意味しない。利用側は全体成功を確認してから次batchを開始する。

### 状態と排他

- 受付内部の状態は`starting / idle / busy / restarting / unavailable / stopping`を基本案とする。
- task予約と再起動予約は同じlockで判定・確定する。通信・process待機中はlockを保持しない。
- `idle`への復帰は、現在の子の起動確認または現在のjobの終了処理だけが行う。
- 起動確認では`listener_id`、`server_id`、protocol版、子processの存続を照合する。
  PID・Julia版・Syncopade版は診断情報として返す。PIDは再利用され得るので識別の正本にしない。
- 再起動要求には照会で得た期待`listener_id`と期待`server_id`を指定する。
  古いIDによる要求は拒否し、応答を失った要求の再送で新しい子をもう一度止めない。
- 子が異常終了した場合は`unavailable`にし、明示的な再起動で復旧する。
  自動再起動・task自動再実行は行わない。

### 互換性と通信

- 公開portの所有者は受付のみとする。計算Juliaは公開LANで待ち受けない。
- 親子通信はloopbackの動的portを使う専用socketを第一案とする。
  接続先と起動IDを子起動時に渡し、対応する子だけを登録する。
- taskの`stdout/stderr`を制御通信に使わない。`println`で通知が壊れない構成にする。
- 文字列引数・結果・例外情報を運ぶ。Juliaアプリケーションの型付きオブジェクトは受付へ渡さない。
- 旧`STATUS|idle` / `STATUS|busy`と、受付成功`OK|STARTED|job_id`を維持する。
  `starting/restarting/stopping`は旧照会ではbusy、子が使えない場合はdownとして表す。
- 再起動中の新規task拒否は既存の`ERROR|BUSY`を使う。
  新しい`ERROR|RELOADING`分類をconductorへ追加しない。
- 起動ID・詳細状態は新しい状態照会で取得する。既存STATUSや結果payloadにfieldを追加しない。
- `RESULT`、`TASK_RESULT`、`DONE`の公開形式を維持する。
  受付が子の結果を照合して、既存形式でcallbackとDONEを送信する。
- `CACHE_CLEAR`は計算Juliaの関数cacheに転送する。計算Juliaの交換とは別操作として残す。
  正常完了は従来の`CACHE|CLEARED|count`、転送不能・応答不明は成功として返さない。

### 起動・終了とtimeout

- `julia scripts/run_server.jl`と`julia syncopadeServer.jl`で受付と計算Juliaが起動する。
- sourceの`include`だけではsocketや子processを作らない。
- 子は同じJulia実行ファイルを用い、Project、作業directory、ENV、thread設定の扱いを仕様化する。
  アプリケーションpackageは受付にロードしない。
- 起動・停止の制御待ちには設定可能な期限を設ける。計算実行時間の上限は追加しない。
  制御期限の数値はStep 6 Phase 2で固定し、過去の900秒を計算期限として流用しない。
- 旧子の終了を確認してから新子を起動する。停止未確認・新子起動失敗では受付を利用不可に保つ。
- 再起動の成功応答は新子の起動確認後だけに返す。
  呼出し側timeoutは成否不明として状態照会で確認し、再起動要求を自動再送しない。
- `q`、EOF、通常の割込み終了では新規受付を止め、実行中taskの扱いと子の回収を明示する。
  通常終了は計算・通知完了を待って子を終了する方針とする。
- 親が突然失われた場合、子は専用接続の切断を検出して次taskを受けない。
  応答不能の計算やアプリケーション自身が起動した孫processを含めた強制回収は、今回の保証に含めない。

## 共通運用と停止条件

- 各Stepは目的、対象、完了条件、検証方法を持ち、一度に1 Step・1 Phaseだけ進める。
- Phase 1: 実装方針とメモ。Phase 2: 関数名、引数、戻り値、例外、副作用、所有者、lock境界。
  Phase 3: 実装。Phase 4: 検証と結果記録。各記録を省略・後付けで完了扱いにしない。
- A進行はPhaseごと、B進行はStepごとに先生の指示を待つ。C進行は確認済みTodo内を順番に進める。
- 強化Cでは、Todoの意味を変えない灯子の誤字・構文・Markdown等のミスだけ修正して同じ検証をやり直す。
- 前提・仕様・Step順序・完了条件の変更が必要なら停止し、Todo全体の見直しを提案する。
- Phase 4の成功後、各Stepの対象差分と記録をcommit/pushする。Todo作成だけで実装Stepを開始しない。
- 試験は専用子process、一時directory、loopback、動的portで隔離する。
  既存の実運用server/conductorへ接続しない。lan100試験もこのTodoには含めない。
- 外部package取得やregistry更新を要しないローカルfixtureを使う。
  fixture用packageはテスト材料であり、本Projectにローカル`path`依存を追加しない。
- 起動したprocessとsocketの回収を検証する。失敗時の強制終了は試験が所有するprocessに限定する。
- コマンド、exit code、assertion結果、ID/PIDの前後、関連logの場所を該当Phase 4に記録する。
- `logs/conductor_events.csv`とsibling repositoryを変更・stage・復元しない。
- version更新、tag、リリース、本番nodeへの展開は別途指示を受けて扱う。

## Step一覧

| Step | 独立して確認すること |
|---|---|
| 1 | 関数cache消去とpackage再ロードの違いを回帰試験にする |
| 2 | 計算処理を受付から切り出し、既存の挙動を保つ |
| 3 | 受付ID・計算IDと排他的な状態遷移を定義する |
| 4 | 親子の専用通信の形式・ID照合を作る |
| 5 | 計算用Juliaの実行ループを単独で動かす |
| 6 | 受付による子の起動・起動確認・終了を作る |
| 7 | 通常taskを子Juliaへ接続し、既存の結果を返す |
| 8 | 子の異常終了を検出し、taskの失敗を回収する |
| 9 | 既存CACHE_CLEARを子へ転送する |
| 10 | idle時だけ子を交換する再起動操作を作る |
| 11 | 起動ID照会・再起動の公開APIとCLIを用意する |
| 12 | conductorの一斉操作と投入・配送を排他にする |
| 13 | 全nodeへ並行して再起動を指示し、結果を集計する |
| 14 | 一斉再起動・結果照会の公開APIとCLIを用意する |
| 15 | 受付を維持したpackage更新反映を実証する |
| 16 | conductor・複数node・一斉操作の接続を確認する |
| 17 | 起動wrapperと通常終了の回帰を確認する |
| 18 | 全体回帰と運用文書を整える |

以下の新規ファイル名・関数名は配置案。各Step Phase 2で正確なinterfaceを固定する。

## Step 1: cache clearで更新できる範囲を試験にする

- **目的:** 原因と修正後の合格基準を保存する。
- **対象:** `test/regression_package_reload_boundary.jl`、`test/fixtures/package_reload/`（新規）、このTodo。
- **方針:** 現行`call_func`と`clear_function_cache!`を使う。製品コードは変更しない。
- **完了条件:** task単体のV1→V2はclear後に反映し、同じUUIDのpackageは旧JuliaにV1が残り、新規JuliaでV2になる。
  同一路径上書きと別の配置directoryへの切替を区別する。後者も同じUUIDで試す。
- **検証方法:** 旧/新marker、module同一性、process IDをassertする。
  `--compiled-modules=no`でも再現することを確かめ、ディスク上のprecompile cacheと切り分ける。
  各条件を別子processで実行し、exit 0とfixture以外への書込みなしを確認する。
- [x] Phase 1 — 実装方針・メモ
  - 既存serverをincludeする独立Juliaでtaskのみ・同一路径package更新・配置先切替を別々に実行する。
    packageは固定UUIDのローカルfixtureをLOAD_PATHから読む。Pkg操作・外部取得を使わない。
    task moduleの置換警告は試験内で捕捉し、実際に置換されたことと依存module再利用を別々にassertする。
- [x] Phase 2 — fixture・観測・入出力・副作用の仕様
  - `reload_call(path, module_name)`は既存call_funcを呼び、置換警告だけを一時stderrへ捕捉して戻り値を返す。
    package taskの戻り値はmarker、PID、package読込path。`loaded_module`で現在のtask/dependencyを観測する。
  - 親試験は3条件を別processで実行しexit 0を検査。各子はmktempdir内へfixtureをcopyし、
    task-onlyは関数cache保持→clear→新版、package条件はclear後旧値・新Julia新版をassertする。
    fresh起動も`--compiled-modules=no`、本repo Projectを用い、PIDが異なることを検査する。
    一時ファイル・LOAD_PATH変更は試験process内だけ。製品ファイルやregistryへの書込みはしない。
- [x] Phase 3 — 実装
  - 固定UUIDのV1/V2 fixtureと独立process回帰試験を追加。製品コードは未変更。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/regression_package_reload_boundary.jl`: exit 0。
    task 9/9、overwrite 13/13、switch 14/14、親process検査3/3。stderrなし。
    overwrite PID 51964→51967、switch 51968→51969、いずれも旧process V1・新process V2。
    各processは同期wait済み、一時fixtureは自動回収。`git diff --check`成功、既存log SHA-256不変。
    初回試験も成功したが子stdoutを表示しない呼出しだったため、観測を表示する形で再実行した。
    このStepの対象のみcommit/pushする（commitはこの記録を含むGit履歴で追跡）。

## Step 2: task読込み・実行処理を切り出す

- **目的:** 計算子が既存の読込み経路をそのまま利用できるようにする。
- **対象:** `syncopadeServer.jl`、`syncopadeExecutor.jl`（新規）、Step 1試験、このTodo。
- **方針:** path解決、関数cache、include、`call_func`を1つの正本へ移す。
  このStepでは既存server内から同じ処理を呼ぶ状態を保つ。
- **完了条件:** path解決の候補順、String引数、戻り値、例外、cache件数とLRU挙動が変わらない。
  sourceのincludeは起動を伴わず、読込みロジックの複製がない。
- **検証方法:** Step 1、既存server admission/result試験、cache有効/無効の小さい単体試験。
- [x] Phase 1 — 実装方針・メモ
  - cache・path・include・実行の定義をそのまま`syncopadeExecutor.jl`へ移し、serverからincludeする。
    実行processの変更はまだ行わない。状態/公開protocol/entrypointはserverに残す。
- [x] Phase 2 — 移動する関数と互換入口の仕様
  - `configured_mount_root/configured_function_cache_size`、path helper、cache lookup/store/clear、
    `load_remote_function/call_func`とその定数/lock/dictを移す。引数・戻り値・例外を変えない。
    Mainへのinclude・invokelatestを維持。source includeは定義だけでsocket/process副作用なし。
  - cache size 0/不正値/上限2のLRUとpath候補順を`test/unit_executor_loading.jl`で確認する。
    fixture copy以外の書込みはなく、ENVはwithenvで復元する。
- [x] Phase 3 — 実装
  - 定義を移動しserverのincludeを追加。単体試験を追加。公開task実行経路は従来のまま。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/<file>.jl`でloading 31/31、
    server admission 16/16、result protocol 43/43、Step 1（9+13+14、親3）すべてexit 0。
    overwrite PID 52003→52004、switch 52049→52092。stderrなし。
    diff whitespace検査成功、既存log hash不変。対象のみcommit/push。

## Step 3: 2つの起動IDと受付状態を定義する

- **目的:** task投入と再起動のどちらか一方だけが予約を取れるようにする。
- **対象:** `syncopadeServerRuntime.jl`、`test/unit_server_runtime_state.jl`（新規）、このTodo。
- **方針:** networkから独立した状態操作を先に作る。現行serverへの接続はStep 7。
- **完了条件:** listener IDは子交換で不変、server IDは子起動ごとに変わる。
  `idle -> busy`と`idle -> restarting`は同時成立しない。
  古い起動IDまたは不一致jobの完了通知では現在状態を変更できない。
- **検証方法:** 遷移表、二重予約、期待ID不一致、unavailableからの明示復旧を決定的な順序で試す。
- [x] Phase 1 — 実装方針・メモ
  - Runtimeは専用lockで状態・2起動ID・実行中jobを一体管理。予約後の通信/計算はlock外。
    unavailableでも通知完了前のjobを残し、再起動はjob解放後だけ許す。
    終了要求フラグはbusy jobを消さず、通知後のidle復帰を禁止する。
- [x] Phase 2 — 状態record・遷移・lock・戻り値の仕様
  - `ServerRuntime()`はUUID文字列2個、starting、空job、停止falseとlockを持つ。
    `runtime_snapshot`はlock内で不変NamedTupleをcopyする。
  - `runtime_mark_ready!`は期待ID一致かつstarting/restartingからのみidleへ。
    `runtime_reserve_job!(runtime, job_id)`はidleからbusyへ、成功時snapshot・拒否時nothing。
    `runtime_reserve_restart!(runtime, listener_id, server_id)`はidle/unavailableかつjobなしで
    restartingへ移す。戻り値`:accepted/:busy/:id_mismatch`。
  - `runtime_replace_server_id!`はrestarting・期待ID一致時だけ新UUIDを発行。
    `runtime_finish_job!`は3 ID照合後jobを消し、busyならidle、unavailableならそのまま、停止要求時はstopping。
    `runtime_mark_unavailable!`は旧IDを無視し、jobを保持。`runtime_request_stop!`は新予約を禁止する。
    純粋な状態変更だけでsocket/process副作用なし。空job IDはArgumentError。
- [x] Phase 3 — 実装
  - Runtime本体と遷移試験を追加。実serverにはまだ接続していない。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/unit_server_runtime_state.jl`: exit 0、
    32+10+111=153/153。task/restart競合32回は成立が常に片方だけ。
    stale ID/jobによる変更拒否、失敗後通知待ち、停止後idle復帰禁止を確認。`git diff --check`成功。
    process/socket起動なし。対象のみcommit/push。

## Step 4: 親子の専用通信を作る

- **目的:** ID、String引数、結果、例外、制御応答を混同せず渡す。
- **対象:** `syncopadeExecutorProtocol.jl`、`test/unit_executor_protocol.jl`（新規）、このTodo。
- **方針:** 起動確認、実行要求/結果、cache clear、終了要求/応答を定義する。
  transport上のframe境界と長さ検証を決め、taskの標準出力とは別経路を使う。
- **完了条件:** protocol版、listener/server/job IDを照合できる。
  空文字、改行、`|`、Unicodeを損失なく送受信でき、不正frameは実行前に拒否する。
- **検証方法:** IOBufferまたはloopbackで分割read、途中EOF、不正長、ID不一致を試す。
  codecの往復だけでなく、未知の応答を状態へ適用しないことを確認する。
- [x] Phase 1 — 実装方針・メモ
  - 専用socketで長さ付きUTF-8文字列列を運ぶ。Julia Serializationやtask stdoutは使わない。
    frame全体長・field数・各field長を検証してからメッセージ解釈する。
    protocolを独立moduleに置き、IDやcommand不一致を状態更新前に例外として拒否する。
- [x] Phase 2 — メッセージ・frame・失敗時の仕様
  - `ExecutorMessage(kind, listener_id, server_id, request_id, data::Vector{String})`。
    wireは32bit big-endianの全体byte長、field数、各fieldのbyte長+UTF-8。
    fieldは版`1`、kind、listener/server/request ID、data。上限16 MiB・4096 field。
  - `READY`は空request ID、PID/Julia版/Syncopade版。`EXECUTE`はjob UUIDとfile/module/func/args。
    `RESULT`は同じjob UUIDとOK/resultまたはERROR/errorType/message。
    `CLEAR/CLEARED`は要求UUIDと空data/非負件数、`STOP/STOPPED`は要求UUIDと空data。
    起動IDはUUIDとして検査する。異常frameはArgumentError、途中EOFはEOFError。
  - `write_executor_message/read_executor_message`がIOを所有せずcodec処理、
    `expect_executor_message`が期待kind・2 ID・request IDを照合。失敗時はruntimeへ適用しない。
- [x] Phase 3 — 実装
  - 専用codecとIOBuffer/loopback分割転送試験を追加。公開protocolと製品serverは未変更。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/unit_executor_protocol.jl`: exit 0、45/45。
    Unicode/改行/pipe/空文字、分割転送、途中EOF、長さ上限、未知command/版、ID不一致を確認。
    不一致応答後のruntime不変とsocket回収を確認。diff検査成功。対象のみcommit/push。

## Step 5: 計算子の実行ループを作る

- **目的:** 常駐する1本のJuliaで複数taskを順に処理できるようにする。
- **対象:** `syncopadeExecutor.jl`、`scripts/run_executor.jl`、
  `test/integration_executor_loop.jl`（後2件は新規）、このTodo。
- **方針:** 試験用の親から専用接続を作り、Step 2の実行処理を呼ぶ。
  計算子は公開callback・DONEを送らない。
- **完了条件:** 連続taskが同じPID/server IDで動く。成功と関数例外を親へ返し、例外後も次taskを実行できる。
  cache clear・停止にも応答し、stdoutへの大量出力が制御通信を壊さない。
- **検証方法:** 軽量task2件、例外task、後続成功taskを実processで順に実行。
  親接続切断時に待受中の子が終了し、socket/processが残らないことも確認する。
- [x] Phase 1 — 実装方針・メモ
  - 子はloopbackへ接続しREADYを送信、1件ずつEXECUTE/CLEAR/STOPを処理する。
    計算例外だけをRESULT ERRORに変換し、通信/不正protocolの失敗は子を終了させる。
    親切断は待受中にEOFとして正常終了する。通信socketと標準出力は完全に分離する。
- [x] Phase 2 — 子entrypoint・実行loop・例外の仕様
  - `executor_main(args)`のargsはport/listener UUID/server UUIDの3個。接続先は127.0.0.1固定。
    socketはfinallyでclose。`run_executor_loop(io, listener_id, server_id)`はREADYから開始し、
    EXECUTEのfile/module/func/String argsをcall_funcへ渡す。結果はstring化、例外分類は現行serverと同じ。
    CLEARはclear_function_cache!の件数、STOPはSTOPPED送信後return。EOFはreturn。
  - `scripts/run_executor.jl`は直接実行時だけexecutor_mainを呼ぶ。
    fixtureはecho/PID/明示例外/256 KiB stdout関数。試験は2子を順に所有し正常STOPと親切断を検証。
    起動/試験通信のwatchdogは20秒、計算時間の製品制限ではない。終了後exit/stderr/portを検査する。
- [x] Phase 3 — 実装
  - 子loop・entrypointと独立実process試験を追加。taskエラー分類を関数化した。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/integration_executor_loop.jl`: exit 0、33/33。
    正常STOP子PID 52800、親切断子PID 52825、いずれもexit 0・再bind可能。
    loading回帰31/31もexit 0。diff検査成功。対象のみcommit/push。
  - 初回は警告が必ず3行という灯子の試験誤り（32成功/1失敗）。独立include2回で
    moduleは交換されるがJulia 1.12.3では警告0行と確認し、既知警告だけ許す検査へ修正・再検証した。

## Step 6: 子の起動と終了を受付側で管理する

- **目的:** 起動済みか不明な子をreadyとせず、確実に所有・回収する。
- **対象:** `syncopadeServerRuntime.jl`、`test/integration_executor_lifecycle.jl`（新規）、このTodo。
- **方針:** 子起動command、process handle、専用接続、起動確認、停止・waitを管理する。
- **完了条件:** 同じJulia、Project、cwd、指定ENV・thread設定で子を起動できる。
  正しい起動応答を得る前はidleにならず、起動失敗・応答期限超過を区別できる。
  起動に失敗した子も回収し、停止完了はprocess終了で判定する。起動ID付きの起動・終了記録を残す。
- **検証方法:** 正常子、起動前例外、起動応答なし、ID不一致のfixtureを使う。
  親の状態・子exit code・残留processとportを確認する。制御期限だけを短縮して試す。
- [x] Phase 1 — 実装方針・メモ
  - pure Runtimeとは別にSupervisorが起動設定・子handle・通信排他・監査出力を持つ。
    状態lock内ではsnapshotと状態適用だけを行い、別のlifecycle lockで起動/停止を直列化する。
    READY検証・process存続確認前はidleにしない。失敗時は所有子を終了/waitしunavailableにする。
- [x] Phase 2 — launch設定・期限・resource所有者の仕様
  - `ExecutorLaunchConfig`はactive Project directory、cwd、ENVのcopy、default/interactive thread数、
    実行scriptを保持。同一`Base.julia_cmd()`に明示project/cwd/threadsとstartup-file=noを指定する。
    起動30秒、停止10秒、失敗時回収はTERM/KILL各2秒を既定とし、
    `SYNCOPADE_EXECUTOR_STARTUP_TIMEOUT/SHUTDOWN_TIMEOUT/CLEANUP_TIMEOUT`で正の有限秒へ変更可能。
    計算exchangeにはtimeoutを追加しない。
  - `ExecutorSupervisor(runtime; config, audit)`は子handleとlifecycle lockを所有。
    `launch_executor!`はloopback listen→spawn→READY照合→PID/存続確認→idle、失敗時は回収してunavailable。
    `stop_executor!`は再起動/終了/利用不可状態でSTOP→STOPPED→process wait、子handleを解放する。
    停止期限超過は強制回収できても失敗として返し、勝手に新版を起動しない。
  - `executor_exchange(child, message, expected_kind; timeout=nothing)`は専用通信を排他し、IDを照合する。
    制御timeoutはsocketをcloseして読み待ちを解除。戻り値はmessage、例外は元のIO/検証例外または制御timeout。
    起動/停止の戻り値はok/reason/message/pid。auditにはイベント・2 ID・PID・理由を出す。
    fixtureの異常終了/READYなし/ID違いと停止無応答を試験し、試験所有の全子を回収する。
- [x] Phase 3 — 実装
  - Supervisor/config/制御timeoutと監査を追加。未接続の起動失敗子もprocess handleを保持し、
    回収を確認できなければ次の起動を拒否する。設定継承・異常fixtureを追加。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/integration_executor_lifecycle.jl`: exit 0、120/120。
    正常PID53269、起動前exit53270、例外53271、READYなし53272、ID違い53315、停止無応答53316。
    全ケース子回収・制御port再bind成功、正常子exit 0。Project/cwd/ENV/2 thread継承を確認。
    runtime状態試験153/153もexit 0。diff検査成功。対象のみcommit/push。
  - 初回の灯子の試験誤りはmacOS `/var`と`/private/var`の文字列比較（101成功/1失敗）。
    実体pathで比較するよう修正して全件再実行した。運用前提や仕様の変更はない。

## Step 7: 受付から子へ通常taskを接続する

- **目的:** 公開serverを受付と計算に分離し、既存clientから計算できるようにする。
- **対象:** `syncopadeServer.jl`、`syncopadeServerRuntime.jl`、
  `test/integration_listener_execution.jl`（新規）、既存server admission/result試験、このTodo。
- **方針:** job ID発行と予約は受付に残し、task読込み・実行だけを子へ移す。
  結果照合、callback、DONE、最後の予約解放は受付が所有する。
- **完了条件:** 受付PIDと計算PIDが異なり、受付にfixture packageがロードされない。
  直接投入とconductor metadata付き投入の既存応答形式が保たれる。
  同時実行最大1、予約前の成功応答なし、計算中も受付のSTATUSに応答できる。
  jobとlistener/server IDの対応を記録し、旧子由来の応答を別jobへ適用しない。
- **検証方法:** loopbackで成功・関数例外・並行投入を確認。
  計算を待機点で保持し、受付の応答と排他を確認する。既存result/admission試験も通す。
  CACHE_CLEARの子転送はStep 9で接続する。それまでは未対応を明示して拒否し、
  親の空cacheを消して成功応答する経路は残さない。この中間状態を実運用へ投入しない。
- [x] Phase 1 — 実装方針・メモ
  - 受付handleが公開socket、Supervisor、accept task、実行taskを所有する。
    Runtimeの予約でjob UUIDを登録してからSTARTEDを返し、子結果のID照合後に親がcallback/DONEを送る。
    serverのincludeは引き続き定義だけ。既存単体試験向けの旧状態関数は互換入口として残す。
    受付を止め子を回収する内部cleanup入口を用意し、mainへの通常終了接続はStep 17で検証する。
- [x] Phase 2 — 受付・実行・通知・解放の仕様
  - `syncopade_server(bind_ip, port; config, audit, output, errors)`はListenerHandleを返す。
    port=0なら実割当portをhandleに保持してDONEにも使用する。startup/acceptは独立task。
    `stop_listener!`は新受付を閉じ、起動task・実行job・接続処理を回収して子を停止する。
  - `handle_server_connection!`はSTATUSと未対応CACHE_CLEAR拒否、task解析/予約/STARTEDを担当。
    job UUIDは予約候補として作り、拒否時は公開しない。予約取得後のsocket失敗では同じjobだけ解放する。
  - `execute_listener_job!`は子へEXECUTE、応答照合、既存RESULT/TASK_RESULT/DONE送信、finallyで同じID/jobを解放。
    処理済み関数例外は子の分類をそのまま返す。通信消失はEXECUTOR_UNAVAILABLEとして区別しunavailableへ。
    自動検出/終端競合の詳細検証はStep 8。監査にjobと起動IDを残す。
  - loopback試験はPID/fixture package未load、task成功/例外、conductor付きDONE、待機点での並行拒否とSTATUSを検証。
    task/sourceはローカルfixture、ファイル待機点は試験の一時directoryだけ。
- [x] Phase 3 — 実装
  - 公開受付をSupervisorへ接続、結果/DONEは親側のまま。CACHE_CLEARは中間段階として明示拒否。
    実受付を所有/回収する試験helperとpackage/待機点fixture、公開経路試験を追加した。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/integration_listener_execution.jl`: exit 0、29/29。
    親PID53827/子53830、listener 2f274ce1-8351-43c5-849c-40c552a05bce、
    server 06a090cf-7679-476d-8787-36e082e51444。3 job成功/例外通知、busy拒否4件、親package未loadを確認。
    既存admission16/16、result43/43もexit 0。子終了/公開port回収・diff検査成功。対象のみcommit/push。
  - 灯子の局所ミスを修正して再検証: TCPServerの名前空間漏れ、@asyncへ渡す予約変数の固定漏れ。
    後者は予約をletで固定してから元変数を解放する変更で、仕様/Step順の変更なし。
    stderr検査は実際の正常precompile表示をエラー扱いしたため、UUIDs/fixtureの成功表示だけを明示許可。
    子のDEPOTも一時directoryへ隔離した。途中失敗試験の残留子なしをpsで確認済み。

## Step 8: 子の異常終了を回収する

- **目的:** 子だけが落ちた場合に、受付済みtaskと受付状態が取り残されないようにする。
- **対象:** `syncopadeServerRuntime.jl`、`syncopadeServer.jl`、
  `test/regression_executor_failure.jl`（新規）、このTodo。
- **方針:** 子exit、接続切断、結果受信との競合を受付の同一jobへ集約する。
- **完了条件:** 関数例外とprocess消失を区別する。
  受付済みjobの失敗をcallback・DONEへ反映し、終端を二重確定しない。
  子消失後はunavailableとなり、自動再実行しない。
  計算の副作用が既に起きた可能性は残るため「未実行」とは報告しない。
- **検証方法:** 試験所有の子だけを待機点で終了させる。
  実行前/中、結果受信直後、古いIDの遅延結果を試し、通知と状態を照合する。
- [x] Phase 1 — 実装方針・メモ
  - 子exit監視は状態をunavailableにするだけで、callback/DONEを送らない。
    終端通知の所有者は受付済みjob task一つに限定する。結果適用前に現在の3 IDを再照合する。
    明示STOPの子exitは監視が異常扱いしない。古い子/古いjobの応答は監査して捨てる。
- [x] Phase 2 — 異常分類・一度だけの終端確定の仕様
  - child handleへexpected_exit/monitor taskを追加。`monitor_executor_exit!`はwait後、現在の子だけを
    unavailableにし専用接続を閉じる。通知中jobは残す。正常STOPはexpected_exitを先に立てる。
  - `runtime_job_is_current(runtime, reservation)`でlistener/server/jobとbusy/unavailableをlock内照合。
    受付jobは実行前・結果受信後・例外処理・DONE前で検査し、不一致なら通知/解放をしない。
    監視と通信EOFが両方来てもcallback/DONEの所有者を増やさない。
  - 試験はidle exit、実行中exit、結果受信後/DONE ack待ち中exit、内部状態を切替えた遅延結果を分離。
    強制終了は試験所有子へのSIGKILLのみ。副作用の可能性をERRORに残し、再実行しない。
- [x] Phase 3 — 実装
  - 子exit監視と現在job照合を追加。監視は終端通知を送らず、遅延結果は通知前に破棄する。
    idle/実行中/結果後の子消失と、古い応答による別job解放防止の試験を追加。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/regression_executor_failure.jl`: exit 0、35+12+12=59/59。
    予約直後/実行前の子消失も境界を固定して確認。通知1回、再起動/再実行なし、遅延結果では別job不変。
    lifecycle120/120、公開実行29/29もexit 0。試験所有の子/portは全回収。diff検査・既存log hash不変。
    起動ID/PID/終端件数は試験内auditとassertionで照合。対象のみcommit/push。

## Step 9: CACHE_CLEARを計算子に届ける

- **目的:** 現行の軽いcache clearを引き続き使えるようにする。
- **対象:** `syncopadeServer.jl`、`syncopadeExecutor.jl`、
  `test/integration_executor_cache_clear.jl`（新規）、このTodo。
- **方針:** 子の関数cacheを消し、確認した件数だけ既存形式で返す。
  再起動との同時実行を制御し、対象server IDを照合する。
- **完了条件:** 成功時にlistener/server IDとPIDは変わらない。
  taskファイル更新は反映され、packageのロード状態は残る。
  子不在・再起動中・応答不明を`CLEARED`成功として返さない。
- **検証方法:** Step 1のtask単体更新を公開CACHE_CLEAR経由で確認する。
  busy中の制御応答・既存の1秒timeoutとの関係を試し、即時応答できる保証がないことを明示する。
  conductorのcache clear集計へ正常/失敗が正しく伝わることも確認する。
- [x] Phase 1 — 実装方針・メモ
  - cache消去も受付側で1枠を予約し、task/再起動と重ねない。ただしjob IDとは別の制御要求IDを使う。
    idle時だけ子へ転送し、busy/起動中/交換中は明示拒否する。関数cacheの確認件数だけ成功応答へ使う。
    応答待ち期限で専用接続を失った場合はunavailableに保ち、成功とは返さない。
- [x] Phase 2 — cache制御の応答・競合・timeout仕様
  - Runtimeへcontrol_idを追加し`runtime_reserve_cache_clear!`でidle→busy、
    `runtime_finish_cache_clear!`で期待2 IDとcontrol IDを照合して解放する。job_idは空のまま。
    `clear_listener_cache!`はCLEAREDを照合して件数を返し、finallyで制御予約を解放する。
  - 公開応答は成功`CACHE|CLEARED|count`、busy`ERROR|BUSY`、子不在`ERROR|CACHE_CLEAR_UNAVAILABLE`、
    通信/検証失敗`ERROR|CACHE_CLEAR_FAILED`。期限は`SYNCOPADE_EXECUTOR_CACHE_TIMEOUT`既定5秒。
    既存conductorの1秒より長いので、conductor側timeoutだけでは消去未実行を意味しない。
    busy中は待機せず拒否する。idleでもcold起動等で1秒以内を保証しない。
  - コピーしたtaskをV1→V2へ書換え、clear前旧関数/clear後新版・同一子を確認。
    同じ子のpackageは旧moduleのまま。既存conductor集計を試験内moduleで呼び、正常/拒否の件数を検証する。
- [x] Phase 3 — 実装
  - 子CLEAR転送と独立の制御予約を追加。public試験の中間未対応assertを正常応答へ更新。
    wrapper/package変更・busy・子不在・制御timeout・既存conductor集計を試験化した。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/integration_executor_cache_clear.jl`: exit 0、11+16+21=48/48。
    taskV1→taskV2、package V1維持、起動ID/PID不変、CLEARED件数、busy/子不在/timeout拒否を確認。
    conductor既存集計は正常1/1・busy失敗1/1。内部logは一時directoryだけ。
    runtime153/153、公開実行29/29もexit 0。diff検査・既存log hash不変。対象のみcommit/push。

## Step 10: 計算子だけを再起動する

- **目的:** 受付を維持して古いpackageを持つprocessを交換する。
- **対象:** `syncopadeServerRuntime.jl`、`syncopadeServer.jl`、
  `test/integration_executor_restart.jl`（新規）、このTodo。
- **方針:** 期待する2つの起動IDを検証して再起動を予約し、旧子終了→新子起動→起動確認の順に処理する。
  詳細状態照会と再起動commandを追加する。unavailableからも明示的に復旧できるようにする。
- **完了条件:** listener ID・受付PID・公開socketを保ち、server IDが変わる。
  busy中は拒否し、再起動中のtaskはBUSYで未受理とする。
  同時要求や古いIDの要求で二重交換しない。停止/起動失敗は成功扱いにしない。
- **検証方法:** 正常交換、task予約との競合、二重再起動、旧子停止失敗、新子起動失敗、
  成功応答を失った後の旧ID再送を試す。交換中も同じ公開portで状態照会できることを確認する。
- [x] Phase 1 — 実装方針・メモ
  - RUNTIME照会で現在IDと状態を返し、RESTARTは期待IDを照合して予約する。
    STOP確認→新server UUID→READYの順を守り、失敗は新規投入不可のまま返す。
    応答socket切断でも受理済み交換は最後まで処理し、旧IDによる再送は二重交換しない。
- [x] Phase 2 — 状態照会・再起動command・失敗応答の仕様
  - checksum付き`RUNTIME`要求→`RUNTIME|1|listener_id|server_id|state|listener_pid|server_pid|julia_version|syncopade_version|ready`。
    応答にも既存checksumを付ける。子不在PIDは0、版は空、readyはprocess存続かつidle/busyのときtrue。
  - 要求`RESTART|1|expected_listener_id|expected_server_id`、不正field/UUIDはchecksum付きERROR。
    応答`RESTART|1|status|old_listener_id|old_server_id|`の後にRUNTIMEのID以降8 field、最後にreasonとchecksum。
    statusはsuccess/busy/id_mismatch/stop_failed/startup_failed。old IDは要求された期待値、new側は現在snapshot。
  - `restart_listener_executor!`が状態予約→stop→ID交換→launchを担当。成功は新子READY時だけ。
    `listener_runtime_info`は診断用copyを返す。管理応答の理由文字列は%/pipe/改行/CRをpercent escapeする。
    既存build_payloadは単純joinなので加工を任せず、既存task/result形式は変更しない。
    同時再起動・busy予約・交換中task・停止/起動失敗・応答喪失後再送を試験する。
- [x] Phase 3 — 実装
  - RUNTIME/RESTARTを公開受付へ追加。期待ID照合と旧子停止後の交換を接続。
    停止待機点fixtureと成功/失敗/重複/応答喪失の実受付試験を追加。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/integration_executor_restart.jl`: exit 0、28+24+27=79/79。
    listener 0c48c6bc-1f23-43bf-b22f-fcfc97cd17ba/PID54201/port62113を維持、子PID54204→54208。
    同時4要求で交換1回、応答喪失後の旧ID再送拒否、unavailable復旧、交換中STATUS/BUSY、停止/起動失敗を確認。
    cache回帰51/51もexit 0。最初/最後の子両方の回収をhelperで検査。diff成功。対象のみcommit/push。
  - 初回は意図した停止timeoutによるSIGTERM表示を通常stderr扱いした試験ミス。
    当該fixtureだけ、所有PIDと終了signalを照合した終了表示を除いて通常stderr検査し、全件再実行した。

## Step 11: 公開APIと1 node用CLIを用意する

- **目的:** 先生がnodeを指定してIDを確認し、計算Juliaを交換できるようにする。
- **対象:** `syncopadeClient.jl`、`src/Syncopade.jl`、`scripts/restart_server.jl`、
  `test/unit_server_management_protocol.jl`、`test/integration_restart_cli.jl`（後3件は新規）、このTodo。
- **方針:** 状態照会APIと期待ID付き再起動APIを公開する。CLIは照会→期待ID付き要求→結果確認を行う。
- **完了条件:** 成功・BUSY拒否・ID不一致・起動失敗・成否不明を区別する。
  CLIは宛先、旧/新ID、状態を表示し、全nodeへの暗黙の操作や要求の自動再送を行わない。
  旧serverが新commandを扱えない場合も明示的に失敗する。
- **検証方法:** parser試験とloopback実CLI試験。
  応答timeout後の照会、空/不正ID、未知protocol、失敗時exit code、package export/docstringを確認する。
- [x] Phase 1 — 実装方針・メモ
  - clientは管理応答を厳格にparseし、正常終了・拒否・通信後の成否不明を分ける。
    APIは期待IDを必須とし、CLIだけが照会→要求の順を構成する。自動再送はしない。
    socketはタイマーで期限を設け、timeout時にcloseして通信taskを残さない。
- [x] Phase 2 — API名・引数・戻り値・CLI・終了codeの仕様
  - `query_server_runtime(ip; server_port, timeout=5)`→ServerRuntimeInfo。
    `restart_server_executor(ip; server_port, expected_listener_id, expected_server_id, timeout=60)`→ServerRestartResult。
    戻り値はstatus/旧ID/runtimeまたはnothing/reason/request_sent。送信前通信失敗はtransport_error、
    送信開始後のtimeout/不正応答はunknown。自動再送なし。照会の通信/形式失敗は専用例外。
  - parserはchecksum・版・field数・UUID・状態・PID・ready・成功時のID交換を検査。
    percent escapeは4種だけdecodeする。宛先は明示IP+port、timeoutは正の有限秒。
  - CLI `julia --project=. scripts/restart_server.jl IP PORT [--timeout SECONDS]`。
    終了codeはsuccess=0、明示拒否/停止起動失敗=2、通信/unknown/未対応=3、引数誤り=64。
    照会後の期待IDで1回だけ要求し、宛先と旧/新ID・状態・理由をstdoutへ表示する。
- [x] Phase 3 — 実装
  - 公開型/API/export/docstringと単体CLIを追加。厳格parserと実CLI/timeout/旧protocol試験を追加。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/unit_server_management_protocol.jl`: exit 0、30/30。
    `test/integration_restart_cli.jl`: exit 0、21+20=41/41。実CLIの0/2/3/64、旧protocol拒否、
    送信後timeout→同じ受付への照会→交換完了確認、socket切断・再送なしを確認。
    `test/unit_client_protocol.jl`: exit 0、63/63。package entrypointをincludeして公開exportを検査し、
    試験起動時のpackage precompile表示に依存しない形にした。diff成功。対象のみcommit/push。

## Step 12: 一斉操作と投入・配送を排他にする

- **目的:** 全node再起動の開始時にtaskを取り残さず、一斉操作を識別・照会できるようにする。
- **対象:** `syncopadeConductor.jl`、`test/unit_conductor_restart_operation.jl`（新規）、このTodo。
- **方針:** 変更操作の所有状態とoperation recordを作り、queue・割当て確認、SUBMIT、
  配送、一斉cache clearとの同期境界を定義する。このStepではnodeへの再起動は送らない。
- **完了条件:** 非空queueまたは有効な割当てがあれば全体を拒否する。
  操作開始とSUBMIT/配送予約の競合では片方だけが先に成立する。
  操作中はSUBMITを未受付として返し、monitor照会は継続する。
  同じoperation IDは既存操作を参照し、別の操作が重複して開始しない。
- **検証方法:** networkなしの試験でqueued/reserved/running/dispatch_unknownの各状態、
  投入と操作開始の両順序、同じIDの再照会、別IDの重複操作、例外時の終了処理を検証する。
  既存queue・予約試験でも通常投入の挙動が変わらないことを確認する。
- [x] Phase 1 — 実装方針・メモ
  - 新しい変更操作lockで、投入登録・node予約・一斉操作開始を同期する。通信中は保持しない。
    queueからpop済みでもtask状態がqueued/reservedとして残るため、配送途中の空queueだけで操作を開始しない。
    既存dispatch lock/generationは維持。状態照会・monitorは止めない。
- [x] Phase 2 — operation record・対象確定・lock・照会の仕様
  - `begin_restart_operation!(operation_id, nodes)`はUUIDを検査し、既存IDならexisting、
    他操作/queue/非terminal task/有効node割当てがあればbusy、それ以外はacceptedとrecord copyを返す。
    endpoint重複除去は先に出た設定名を保持。recordはID/対象copy/status/resultsをconductor存続中保持する。
  - `get_restart_operation`はunknownならnothing、既知ならcopy。未完の集計は未確定としてnothing。
    `finish_restart_operation!(id, results)`は全対象が一度ずつ揃うことと所有IDを確認して確定・制限解除。
    確定時だけtotal/success/failedを返し、target>0かつ全成功をoverall_successとする。
  - `enqueue_task!`と2種のnode予約入口を同じ変更操作lockで囲み、再起動操作中は登録/予約しない。
    SUBMITには`ERROR|BUSY|MAINTENANCE`を返す。dispatch入口も休止を確認する。
    既存task/node lockは各snapshot中だけ取得し、変更操作lockを後から取りに戻る経路を作らない。
  - `begin_cache_clear_operation!/finish_conductor_mutation!`でCACHE_CLEAR_ALLも変更操作同士を排他。
    cache clear内部はtry/finallyで所有状態を解放し、例外でも次操作を妨げない。nodeへの再起動送信はまだしない。
- [x] Phase 3 — 実装
  - 一斉操作record/所有lock、投入・node予約の排他、cache操作finally解放を追加。
    public SUBMITは操作中に未受付BUSYを返す。node再起動送信は未接続。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/unit_conductor_restart_operation.jl`: exit 0、30+21+51=102/102。
    24回の投入/操作開始競合は片方だけ成立。queued/reserved/running/dispatch_unknownとnode割当てを拒否。
    同じ操作IDの再参照、対象重複除去、結果copy、0対象非成功、cache例外時解放を確認。
    既存queue20/20、dispatch予約29/29、cache51/51もexit 0。diff成功。対象のみcommit/push。

## Step 13: 全nodeへの並行指示と結果集計を作る

- **目的:** 1回の操作で全設定nodeに指示を行い、部分失敗も漏れなく回収する。
- **対象:** `syncopadeConductor.jl`、`syncopadeClient.jl`、
  `test/regression_conductor_restart_all.jl`、`test/fixtures/controlled_restart_listener.jl`（後2件は新規）、このTodo。
- **方針:** Step 12の操作に、対象endpointの固定、起動ID照会、Step 11の再起動APIの並行呼出し、
  node別結果保存、全体完了、公開commandとoperation照会を接続する。
  成否不明nodeの配送除外と、照会による除外解除もここで接続する。
- **完了条件:** 応答の遅いnodeを待つ前に他nodeへ要求が届く。
  down/busy/旧protocol/ID不一致を除外せず集計し、対象0件を成功としない。
  1台の失敗で他台の収集を打ち切らず、全node分の結果と旧/新IDを返す。
  操作中のclient切断・node timeout後も二重再起動せず、遅延応答で現在状態を巻き戻さない。
- **検証方法:** 応答順を制御できる複数受付fixtureで、全成功・混在結果・部分送信後の切断・
  timeout・operation再照会を試す。件数の整合、未送信と送信後不明の区別、socket/task回収を確認する。
  成否不明nodeにmonitorの旧idleを到着させ、配送除外が解除されないことも検証する。
- [x] Phase 1 — 実装方針・メモ
  - 受理した対象全件の照会/再起動を独立taskで並行開始し、各通信期限で回収する。
    caller接続から独立した収集taskを操作IDに紐付け、再送では追加送信しない。
    送信後unknownだけはnode lockで配送除外を記録し、旧STATUS idleの観測では解除しない。
    monitorからの起動ID照会で同じ受付の新子readyを確認したときだけ除外を解除する。
- [x] Phase 2 — 一斉command・node結果・期限・除外解除・logの仕様
  - `start_conductor_restart!(id, nodes; query_timeout=5, restart_timeout=60)`が受理時だけ収集taskを作る。
    `collect_conductor_restart!`は全対象を先に並行開始し、各結果を記録後にfinishする。
    query失敗はunsupported/transport_error、再起動は単体APIのstatus。予期しない送信後例外はunknown。
    `SYNCOPADE_RESTART_QUERY_TIMEOUT/RESTART_TIMEOUT`で制御期限を変更でき、計算期限とは別。
  - public要求は`RESTART_ALL|1|operation_id`、照会は`RESTART_ALL_STATUS|1|operation_id`。
    応答はchecksum/percent escape付き`RESTART_ALL|1|id|busy/unknown`、
    または`...|running|target_count|completed_count`、確定時は`...|complete|total|success|failed|overall_success`。
    確定応答には対象順に17 field（IP/port/name/status/旧2 ID/request_sent/runtime有無/現在runtime8 field/reason）を続ける。
  - `record_restart_node_result!`は現在操作の未記録endpointだけ更新する。
    unknown送信済みnodeは旧2 IDと操作IDをnode lock下で記録し、state down・generation更新。
    観測適用/予約/LISTで除外を守る。`reconcile_restart_quarantine!`はlock外照会後、
    同じ除外記録・受付ID一致・server ID変更・readyを再照合して解除する。旧idle/別受付では解除しない。
  - 監査は既存CSV列のevent/status/errorを使い、操作IDと旧新IDを記録する。確定履歴は後から書き換えない。
    応答順を制御するloopback fixtureで並行送信、全成功/混在/0対象、通信切断、timeout、遅延/旧idleを検証する。
- [x] Phase 3 — 実装
  - 全対象の並行照会/再起動、操作別収集、public開始/照会command、既存CSV監査を接続。
    unknown nodeの配送除外と起動ID照会による解除を追加。既存generationは維持した。
    controlled fixtureで送信順と応答喪失を固定する試験を追加。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/regression_conductor_restart_all.jl`: exit 0、22+54+5=81/81。
    遅延node待機中に別nodeへ送信済み、同IDで追加送信なし。8対象は成功1/失敗7（busy/旧protocol/ID違い/
    起動失敗/timeout/応答切断/接続不能）。各socket/taskとfixture portを回収した。
    unknown→旧idle拒否/別listener拒否→同listener新server readyで解除。確定履歴は変更なし。
    操作状態101/101、既存node状態55/55、dispatch29/29もexit 0。diff成功。対象のみcommit/push。

## Step 14: 一斉再起動の公開APIとCLIを用意する

- **目的:** 先生がconductorへの1回の指示で全nodeを操作し、内訳まで確認できるようにする。
- **対象:** `syncopadeClient.jl`、`src/Syncopade.jl`、`scripts/restart_conductor_servers.jl`、
  `test/unit_conductor_restart_protocol.jl`、`test/integration_restart_all_cli.jl`（後3件は新規）、このTodo。
- **方針:** 一斉操作開始・operation状態照会・完了待ちを公開APIにする。
  CLIは操作IDと対象conductorを表示し、node別結果と合計を返す。
- **完了条件:** 全成功、開始拒否、部分失敗、操作継続中、記録不明を区別する。
  CLIは対象0件・失敗・成否不明で成功exitを返さない。
  接続断後は同じoperation IDを照会し、新しい一斉再起動を黙って発行しない。
  既存の単体再起動APIとCLIはそのまま利用できる。
- **検証方法:** parserでnode件数・重複endpoint・欠落ID・不正集計を検証し、
  loopback CLIで全成功と部分失敗の表示・exit code、操作IDによる結果回収を確認する。
- [x] Phase 1 — 実装方針・メモ
  - 一斉操作の開始・照会・待機を分離する。待機は同じ操作IDの照会だけを繰り返し、再開始しない。
    runningには確定集計を付けず、completeの全node結果と集計を厳格に照合する。
    実CLIはloopback限定の試験conductor子processとcontrolled nodeで検証する。
- [x] Phase 2 — 公開API・結果型・CLI・終了codeの仕様
  - 公開APIは`start_conductor_executor_restart`、`query_conductor_executor_restart`、
    `wait_conductor_executor_restart`。IP/conductor_portを明示し、開始はoperation_idをcallerで生成（省略時client生成）。
    照会/待機はID必須。開始後通信不明はID付きoutcome_unknown、接続前失敗はnot_startedを返す。
    waitは既定90秒、照会期限5秒・間隔0.1秒、同じIDだけ照会し、記録unknownなら停止する。
  - `ConductorRestartStatus`はID/state/対象数/完了数/node結果/確定summaryまたはnothing/reason。
    `ConductorRestartNodeResult`はIP/port/name/単体結果。parserはfield数、endpoint重複、旧新ID、
    runtime有無、件数合計、成功nodeの定義、0対象非成功を照合する。
  - CLI `scripts/restart_conductor_servers.jl IP PORT [--operation-id UUID] [--status] [--timeout SECONDS]`。
    --statusはID必須で照会のみ。新規開始はIDを先に表示し、応答不明でも同じIDの照会だけで回収する。
    exitは全成功0、busy/部分失敗/0対象2、通信不明/記録unknown3、継続中4、引数誤り64。
  - 試験conductorは子process内でIP=loopback・node一覧・log保存先だけを固定し、実機profileを使わない。
    全成功/部分失敗CLI、同ID照会、操作中拒否、caller切断後回収を実通信で検証する。
- [x] Phase 3 — 実装
  - 一斉API/公開型/export/CLIと厳格parserを追加。local conductor専用子process fixtureを追加し、
    実CLI、同操作IDの照会、caller切断、操作中SUBMIT/CACHE拒否を試験化した。
- [x] Phase 4 — 検証・結果・commit/push
  - bulk parser30/30、実CLI18+22+6=46/46、単体管理parser30/30、既存client63/63すべてexit 0。
    コマンドはいずれも`julia --startup-file=no --project=. --threads=4 test/<file>.jl`。
    実conductor接続を切った後も同IDで結果回収、操作中SUBMIT/CACHE拒否、全成功/部分失敗/0対象/継続中を確認。
    初回の灯子の試験helper誤り（pipeへのclosewrite）は入力pipeのcloseへ局所修正し再実行。
    全conductor子のexit 0・port回収、diff検査、既存log hash不変。対象のみcommit/push。

## Step 15: package更新反映を公開経路で確認する

- **目的:** 今回の目的が受付を落とさず達成されたことを証明する。
- **対象:** `test/regression_package_reload_boundary.jl`、`test/fixtures/package_reload/`、
  `test/integration_restart_package_reload.jl`（新規）、このTodo。
- **方針:** Step 1と同じfixtureを実受付・子・公開API経由で実行する。
- **完了条件:** V1実行→V2へ変更/配置先切替→CACHE_CLEARではV1→子再起動後にV2、を確認する。
  全期間でlistener ID・受付PID・公開portは一定。通常task間では子を再利用し、再起動時だけ交換する。
- **検証方法:** 各段階のmarker、実際のpackage読込path、listener/server ID、PID、cache件数を照合する。
  複数taskでも新子を再利用することを確認する。通常設定とprecompile無効条件を独立processで検証する。
- [x] Phase 1 — 試験方針・メモ
  - Step 1の同UUID package素材を実受付へ投入する。上書き/別配置の2条件を、それぞれ通常/compiled-modules=noの
    独立Juliaで試す。別配置fixtureは自身のdirectoryをLOAD_PATH先頭に置き、配置先選択を明示する。
    関数cache消去とprocess交換の効果を同じ公開portで順に観測する。
- [x] Phase 2 — 観測項目・成功判定・副作用の仕様
  - `deployment_task.jl`はStep 1と同じReloadProbeを読み、marker/PID/pathを返す。LOAD_PATH操作は試験子だけ。
    公開task投入→RESULT読取りで観測し、公開RUNTIME/RESTART APIでID・PID・readyを検査する。
  - 単独task V1→clear→V2を先に確認しcacheを空にする。その後package V1→変更→clear前後V1→
    restart→V2→再度V2。上書き時clear件数1、別配置時は2 path分の2件。
    旧package pathと新配置path、受付ID/PID/socket/port不変、新子ID/PID変更、通常task間子再利用をassertする。
  - 親driverは4条件を子processで同期実行しexit 0を検査。fixture/DEPOT/作業fileは一時directoryへ隔離し、
    すべて所有子をwaitして回収する。アプリのrevision配布機能を追加したとは扱わない。
- [x] Phase 3 — 試験実装
  - 共通fixtureを使う公開経路4条件の試験を追加。試験helperにtask module指定を追加した。
- [x] Phase 4 — 検証・結果・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/integration_restart_package_reload.jl`: exit 0。
    通常overwrite42/42、switch43/43、precompile無効overwrite42/42、switch43/43、親4/4。
    子PIDは順に54715→54722、54727→54734、54739→54740、54742→54743。
    各listener ID/PID/port不変、旧/新package path一致、clear後V1・再起動後V2・新版子再利用を確認。
    auditの起動ID/PID/pathは標準出力へ出力、所有process/port/fixture/DEPOTは回収。diff成功。対象のみcommit/push。

## Step 16: conductor・複数node・一斉操作の接続を確認する

- **目的:** process分離・交換後も既存のqueue、排他、終端通知を保つ。
- **対象:** `test/integration_conductor_executor_restart.jl`（新規）、
  `test/integration_conductor_restart_all.jl`（新規）、
  `test/fixtures/conductor_controlled_worker.jl`、既存conductor regression試験、このTodo。
- **方針:** 単体再起動はloopback上の1受付・1子・1conductor、
  一斉再起動は2受付・2子・1conductorを使い、試験process内だけでnode一覧を固定する。
  実機profileや本番conductorは使わない。
- **完了条件:** 単体再起動中のBUSYでtaskを破棄せずretryを消費しない。
  新子のready後に4件のtaskが各1回実行され、task/job IDとcallback・DONE・terminalが対応する。
  子異常終了時も受理済みtaskの失敗がconductorと投入元へ伝わる。
  一斉操作で2受付のID・PID・公開portを保ち、2子のIDが変わり、両nodeで新版markerを取得できる。
  操作中のSUBMITは未受付として拒否され、全体成功後の新規batchは正常に完了する。
- **検証方法:** 状態遷移を待機点で固定して通常完了、BUSY待機、子消失を別caseで確認する。
  最大同時実行1、重複実行なし、遅延通知で別jobを解放しないことを検証する。
  一斉操作は1台の旧子を待機点で止めて並行指示を確認し、両台の更新後に軽量taskを投入する。
  接続不能な第3endpointを加える部分失敗caseでも、2台の成功と1台の失敗を漏れなく返すことを確認する。
  Steps 12〜14で定義した範囲を超える製品仕様変更が必要なら、Todo全体を見直す。
- [x] Phase 1 — 試験方針・メモ
  - 実受付/実計算子と、loopback専用conductor子processを接続する。
    単体試験はconductorの状態観測後・配送前を試験fixtureだけで保持し、再起動中BUSYを決定的に作る。
    その後4 taskの一度だけの実行とterminalを照合する。一斉試験は2受付の更新と第3到達不能endpointを分離する。
- [x] Phase 2 — fixture・投入・結果照合の仕様
  - local conductor fixtureに観測後の配送gateとmonitor開始gateを追加（製品コードには追加しない）。
    旧子STOP待機→stale idleからの投入でDISPATCH_BUSYを作り、CSV retry=0とqueued維持を確認する。
    旧子停止解除後は通常executorを起動し、4ラベルtaskのcallback/task/job/terminalと実行traceを照合する。
    別caseで実行中子消失→TASK_RESULT ERROR→conductor terminalを確認する。
  - 一斉試験は2受付の同UUID package V1をロード→fixture package V2へ変更→一斉再起動→両V2を確認。
    片方のSTOPを試験専用の子functionで待機点へ固定し、他方の新子起動を先に確認する。
    受付情報は両台不変、操作中SUBMIT拒否、解除後batch4件の正常終了を確認する。
    到達不能第3endpointのcaseでは実2台成功+1失敗を保持する。既存server/conductorには接続しない。
- [x] Phase 3 — 試験実装
  - 試験専用STOP frame gate、local listener processと回収helper、conductor観測/monitor gateを追加。
    単体4 task/異常終了、一斉2受付process/2計算子/1conductor、版更新後4 task、第3到達不能を実装した。
    最初の単体caseの動作確認は67/67。正式なPhase 4では両試験と既存回帰をまとめて再確認する。
- [x] Phase 4 — 検証・結果・commit/push
  - 単体結合49+18=67/67、一斉実process82/82、controlled一斉81/81、既存stale idle26/26、
    DONE identity33/33、terminal callback19/19すべてexit 0（各`julia --startup-file=no --project=. --threads=4 test/<file>.jl`）。
    実受付PID54885/54896、旧子54895/54906→新子54915/54914。conductorを含む5 PIDの独立性をassertした。
    両受付ID/PID/port不変、両package V2、解除後4 task一度ずつ/max_active=1、到達不能込み2成功/1失敗を確認。
    単体BUSY時CSV retry=0と保持、子消失の両終端通知も確認。全子正常回収、diff・既存log hash不変。
    対象のみcommit/push。

## Step 17: wrapper起動と終了を確認する

- **目的:** 過去の「run_serverがすぐ終了する」回帰を防ぎ、子も回収する。
- **対象:** `scripts/run_server.jl`、`syncopadeServer.jl`、
  `syncopadeServerRuntime.jl`（承認済みの子の割込み分離）、`syncopadeServerSignals.jl`（CLI終了要求の受信）、
  `test/integration_server_wrapper_entrypoint.jl`、`test/integration_listener_shutdown.jl`（新規）、関連終了fixture、このTodo。
- **方針:** 直接起動・wrapper起動・include-onlyの3つを区別する。
- **完了条件:** 直接/wrapper起動は受付と子が存続し、include-onlyでは起動しない。
  idle時とbusy時のq/EOF/通常割込みが定義した終了順序に従う。
  通常終了後は所有する子とsocketが残らない。
- **検証方法:** 起動commandを実processで試し、q・EOF・通常割込み後のexit codeとprocess回収を確認。
  busy時は制御可能な軽量fixtureを使う。受付の異常終了時は、子がidleの場合の接続切断終了も確認する。
  実行中の任意コード・孫processを含む強制回収まで検証したと主張しない。
- [x] Phase 1 — 実装・試験方針とメモ
  - mainのfinallyで受付と子を回収し、q/EOF/通常SIGINTは実行中計算と通知の完了を待つ。
    wrapperは直接実行時だけmainを呼び、include-onlyは起動しない。
    実scriptをLANなしで試すため、従来の引数なし動作を維持したまま明示`--bind/--port`を受け付ける。
    既存lan100手動wrapper試験は維持し、新しいloopback終了試験をsuiteへ登録する方針。
- [x] Phase 2 — entrypoint・終了処理・resource回収の仕様
  - `server_entrypoint_options(args)`は引数なしなら既存profile、明示時は`--bind IP --port PORT`の両方を必須とし、
    不正値・重複・未知の引数はsocket作成前に拒否する。port 0はOSによる空きport割当。
    `main(args=ARGS)`はhandleを保持し、q/EOF/通常SIGINTでfinallyから`stop_listener!`を呼ぶ。
    SIGINTをInterruptExceptionとして受け、最初の終了要求では計算と通知完了を待つ（計算期限なし）。
    後始末失敗は正常終了とせず例外。二度目の強制割込み・孫processの回収は保証外。
  - wrapperは`PROGRAM_FILE`が自身の場合だけmainを呼ぶ。includeは定義のみ。
    直接/wrapper×idle/busy×q/EOF/SIGINTをloopbackの実processで検証し、終了code・通知・子PID消滅・port再利用を確認。
    idleの親強制終了も専用の所有processで確認し、子のIPC EOF終了を観測する。
- [x] Phase 3 — 実装
  - mainの引数検証・finally cleanup・SIGINT捕捉とwrapperの直接実行guardを追加。
    `integration_listener_shutdown.jl`で実entrypointの存続、通知完了後の終了、子PID消滅、port再利用を検査。
    各caseはloopbackの動的portと一時DEPOTを使い、既存LAN手動試験・設定は変更していない。
- [x] Phase 4 — 検証・結果・commit/push（初回停止後、下記改訂Phaseで完了）
  - **停止記録:** `julia --startup-file=no --project=. --threads=4 test/integration_listener_shutdown.jl`。
    引数検証とdirect/wrapperのinclude-onlyは17/17。direct起動のidle/busyそれぞれのq/EOFは通過。
    ただしSIGINTは未達。Julia 1.12.3 / macOS / `--threads=4`で次を観測した。
    - idle親PID 55128・子PID 55129・公開port 65209:
      親exit 1、stderr `fatal: error thrown and no exception handler available. InterruptException()`。
      stackは`task_done_hook`→`wait`→`ijl_task_get_next`。mainのcatch/finallyの終了logなし。
    - busy親PID 55142・子PID 55143・公開port 65388:
      listener `562d3ca2-b1b9-4981-ac2f-1efba53a3011`、server `0dfdabd3-358f-4e5c-9043-0b3d4c1ca79f`。
      SIGINT後も受付が閉じず、結果受信がInterruptExceptionとなり`EXECUTOR_UNAVAILABLE` callbackとERROR DONEを返した。
      job `95cb032c-0c2c-4915-8717-96eb766f9869`、task `99bdbf00-ceaa-4657-ab5a-429a71170766`。
      計算を完了させて通常通知を待つという完了条件を満たさない。
  - 推論: `Base.exit_on_sigint(false)`はmainへの配信先固定ではないため、mainのtry/catchだけでは
    非同期処理を持つ受付の終了順序を保証できない。local Julia Baseの`c.jl:184–203`も配信先固定を保証していない。
    誤字修正では済まないので、強化Cの停止条件に従い終了方式の再設計・相互確認を待つ。
    候補はJuliaの終了hookによる回収等だが、計算・通知の継続可否を検証するまでは採用しない。
  - 試験側にも、終了待ちtimeoutのassertion失敗後に無期限`wait`へ進む問題があった。
    試験driver PID 55110を所有確認後にSIGTERMで中断（exit 143）。stdinが閉じ、親55142と子55143も終了。
    3 PIDの消滅と残存公開port/制御portのlistenなしを確認。wrapper起動の終了caseと親突然死caseは未実施。
    次の見直しでは試験のtimeout後にも確実にfinally回収へ進むことを含める。
    未成功のStep 17はcommit/pushせず、Step 18へ進めていない。

### Step 17 改訂Phase（終了処理の見直しを承認後に再開）

- [x] Phase 1 — 方針
  - 受付/計算子の2 process構成・ID・再起動API・全node一斉指示は変更しない。
    mainでInterruptExceptionを捕捉する前提を撤回。Juliaの終了hookを第一候補として、
    既存の非同期結果受信・通知を壊さず待機できるかを先に最小fixtureで確認し、その結果を実装方式の根拠にする。
    q/EOFと割込みの終了処理は一つに集約し、二重回収や途中終了の成功扱いを防ぐ。
  - 子は別process groupで起動して端末Ctrl-Cの直接伝搬を分離する。受付は明示STOP・process waitの所有者を維持。
    親だけへのSIGINTと端末相当のgroup SIGINTを分けて試し、親異常終了時のidle子EOF終了も再確認する。
    試験の期限切れでは無条件waitへ進まずfinallyへ入り、試験所有processを回収する。
  - Step追加・順序変更はなし。Step 17完了後にStep 18の全体回帰・運用文書を行う。
- [x] Phase 2 — 関数仕様・副作用・検証条件
  - 先行fixture `shutdown_hook_probe.jl`は親driverの一時directoryを受け取り、制御可能な非同期処理を起動。
    SIGINT時の終了hookでその処理を待ち、release後の完了markerとhook完了markerが両方あるか確認。
    driverはhook到達/終了に上限を設け、自己待機・scheduler停止の有無を観測する。失敗を成功扱いしない。
  - 本体は終了要求を一度だけ扱い、`stop_listener!`の受付停止→実行/通知待機→子STOP/回収という順序を維持。
    終了hook採用時はq/EOFのfinallyと共通の終了ownerを使う。hook中の非同期処理継続が成立しなければ
    signal受信だけを終了要求へ変換する方式を同じ終了入口の範囲で検討し、根拠と関数仕様を追記してから実装する。
  - 子起動の`Cmd(...; detach=true)`でprocess groupを分離。loopback試験の受付自体も専用groupで起動し、
    group IDが所有する受付PIDと一致することを確認してからgroup SIGINTを送る。他のgroupへ送らない。
    q/EOFはexit 0、SIGINTは後始末の完了を必須とし、OSの割込み終了codeを保持する方式も許容する。
    stderr検査は既知のsignal終了出力を所有PIDと照合する場合だけ局所化し、suite全体の検査は弱めない。
  - 終了試験は最初の失敗で後始末へ進む。実行期限は試験driverだけに置き、実計算には設けない。
  - 先行確認: PID57934の終了hookは中断された仕事と同じJulia Task上で実行された（`self_wait=true`）。
    WORK_DONE/HOOK_DONEはfalse、signal 2終了。hookから同じTaskを待てないため本体には採用しない。
    Julia v1.12.3 `signals-unix.c:533–539`と`base/initdefs.jl:435–440`の実装経路にも対応する。
  - 採用仕様: Julia内蔵libuvの`uv_signal_start`でSIGINTをイベントとして受ける。
    `ListenerInterrupt`はnative handleと原子的なrequested/closed flagを所有。
    callbackはrequested=trueにするだけで、例外・停止・通信・待機を行わない。
    `start_listener_interrupt()`はCLI mainだけで呼ぶ。include/API利用ではsignal設定を変えない。
    `close_listener_interrupt!()`はuv_close callback完了後だけrootを解放し、再呼出しを安全に扱う。
    全native handle操作はJuliaのI/O lock内、callbackはevent loop上で実行。新しい依存package・別processは追加しない。
    根拠: https://docs.libuv.org/en/v1.x/signal.html 、 https://docs.libuv.org/en/v1.x/handle.html 。
  - `main`はstdin読取りを専用Taskにし、終了入力またはrequested flagを待つ。
    どちらからでもfinallyの一か所で`stop_listener!`を呼び、未完了stdin読取りも閉じて回収する。
    signal watcherは後始末完了まで維持し、繰り返しCtrl-Cも同じ依頼へ集約する。
    正常なq/EOFは0、SIGINT依頼後の後始末成功は130を返し、直接/wrapper guardがexit codeへ反映。
    回収失敗は例外（非0）で成功logを出さない。CLI専用のprocess-wide signal設定であり、REPL内mainの利用は保証しない。
- [x] Phase 3 — 実装
  - signal event受信を独立ファイルへ隔離。native callbackはflag更新のみとし、終了ownerはmainのまま。
    正の先行fixtureはself_wait=false、仕事と後始末完了、exit 0/stderr空を確認してから本体へ接続した。
    不採用の終了hook fixtureは原因の再確認用として保存し、通常suiteには登録しない。
  - 実entrypoint試験は引数なしthread数/4 threads、direct/wrapper、idle/busy、q/EOF/親SIGINT/group SIGINTを網羅。
    子group分離、繰返し割込み、GC後のsignal handle寿命、二重close、期限切れ後の確実な回収も検査する。
- [x] Phase 4 — 検証・commit/push
  - `julia --startup-file=no --project=. --threads=4 test/integration_listener_shutdown.jl`はexit 0。
    引数/include-only17、signal独立処理9、実起動終了576、親消失5、合計607/607。
    direct/wrapper×thread未指定/4×idle/busy×q/EOF/親SIGINT/group SIGINTの32 caseを確認。
    q/EOF exit 0、SIGINT exit 130・termsignal 0、全caseで子終了・port再利用・stderr既知成功出力のみ。
    busy割込みを2回送っても結果/ DONEはOK。例: wrapper 4 threads group SIGINTの親58358・子58359・port57929。
  - `integration_executor_lifecycle.jl`120/120、`integration_executor_restart.jl`79/79もexit 0。
    起動失敗回収・停止失敗・旧ID拒否・受付不変の既存検証を維持。
    `scripts/run_server.jl --help`はexit 0。diff check、既存log SHA-256不変を確認。
    実環境はJulia 1.12.3/macOS。Windows console・他Julia版の実機検証を実施したとは主張しない。
    対象8ファイルのみcommit/push。過去の停止記録は削除せず残す。

## Step 18: 全体回帰と運用文書を整える

- **目的:** 再起動機能の使い方と保証範囲を文書化し、既存機能と合わせて検証する。
- **対象:** `test/runtests.jl`、`docs/TESTING.md`、`docs/EXECUTOR_RESTART.md`（新規）、このTodo。
- **方針:** 外部LAN不要の新規試験を独立Julia子process単位でsuiteに登録する。
  期待する子の例外はfixture内で検証・回収し、suiteのstderr検査を丸ごと緩めない。
- **完了条件:** 既存回帰と新規suiteがexit 0。
  単体/一斉操作例、対象profile、IDの寿命、通常cache clearとの差、busy拒否、
  一斉操作中の投入制限、部分失敗、operation照会、batch切替手順が記載される。
  単一process内packageを刷新した試験と、実MDO最適化の未実施範囲を区別する。
- **検証方法:** `julia --startup-file=no --project=. --threads=4 test/runtests.jl`、
  `git diff --check`、文書リンク・公開APIの照合、既存log差分の保全、残留process/port確認。
  合計件数は実測し、過去の654件を今回の結果として転記しない。
- [ ] Phase 1 — 統合・文書方針とメモ
- [ ] Phase 2 — suite登録・文書構成・最終判定の仕様
- [ ] Phase 3 — 実装・文書整理
- [ ] Phase 4 — 検証・結果・commit/push

## 相互確認の要点

1. 受付を常駐させ、同じ計算Juliaを通常task間で使い回す。
2. 2つの起動IDで受付と計算子を識別する。物理node IDや複数版管理は追加しない。
3. batchの切れ目で単体指定または全node一斉指示を行う。計算中の強制再起動はしない。
4. 公開のtask/result protocolを保ち、計算子の起動IDは管理用API・専用通信・logで扱う。
5. 一斉操作は設定された全nodeを対象に、並行して要求し、node別の成否とIDを集計する。
   1台でも失敗・成否不明があれば全体成功とせず、次batch開始前に対処する。
6. 完了判定はlocalの複数process試験まで。本番nodeへの展開・version/tagは別作業とする。

2026-09-16「じゃあ強化cで！」により相互確認完了。Step 1 Phase 1から順に進める。
