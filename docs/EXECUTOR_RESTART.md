# 計算用Juliaの再起動

## 何を更新する機能か

Syncopade serverは、受付Juliaと計算用Juliaの2 processで動く。
受付は接続・実行予約・結果通知・子の起動/停止を担当し、taskのコードと依存packageは計算用Juliaが読む。
通常は同じ子を複数taskで使い回し、明示的な再起動だけで交換する。
conductorはこれらとは別のprocessで、今回の操作では再起動しない。

`CACHE_CLEAR`は子のtask関数cacheを空にするだけで、読み込み済みpackageをアンロードしない。
packageのコードを更新した場合は、ファイルの配備後に計算用Juliaを再起動する。
再起動成功は「新しい子が起動して応答した」ことであり、目的のアプリケーション版が配備された保証ではない。
Project/Manifest、共有ファイルの反映、アプリケーションの版確認は利用側の責務。

## IDと稼働状態

| 項目 | 寿命・用途 |
| --- | --- |
| `listener_id` | 受付起動ごとのUUID。子の交換では変わらない。受付再起動で変わる。 |
| `server_id` | 計算用Julia起動ごとのUUID。子を交換するたびに変わる。 |
| `listener_pid` / `server_pid` | OS上のprocess ID。監査用で、UUIDの代わりにはしない。 |
| task ID / job ID | 既存の投入/実行識別子。上の起動IDとは別。 |
| `operation_id` | conductor全node一斉操作のUUID。開始後の照会・重複操作の防止に使う。 |

受付状態は`starting / idle / busy / restarting / unavailable / stopping`。
従来の`STATUS`、`OK|STARTED`、`ERROR|BUSY`、結果callback、`DONE`の形式は維持する。
詳しいID・PID・状態は`query_server_runtime`で照会する。

再起動はidleで実施する。計算中、結果通知中、cache clear中、別の再起動中は拒否する。
「今の計算が終わったら再起動する」という予約はしない。子が失われた場合の復旧は明示操作で行う。
子の消失で実行が失敗しても、それまでのファイル書込み等が取り消されたとは限らない。

## 単体操作

以下の`SERVER_IP` / `SERVER_PORT`は、操作したい受付のIP/portに置き換える。
任意の実運用serverへそのまま実行するための例ではない。

```bash
julia --project=. scripts/restart_server.jl SERVER_IP SERVER_PORT
# 管理応答の待ち時間だけを変更する場合
julia --project=. scripts/restart_server.jl SERVER_IP SERVER_PORT --timeout 120
```

CLIは現在のIDを照会して、その組を期待値として再起動要求に渡す。
終了codeは成功0、拒否/明示的失敗2、通信失敗/成否不明3、引数誤り64。
失われた成功応答を回復するつもりで、このCLIを単純に再実行しない。新たなIDを照会してもう一度交換してしまう。

API例（IP/portは明示的に設定する）:

```julia
using Syncopade
server_ip, server_port = "127.0.0.1", 8030  # 実際の対象へ置き換える
before = query_server_runtime(server_ip; server_port)
result = restart_server_executor(server_ip;
    server_port,
    expected_listener_id=before.listener_id,
    expected_server_id=before.server_id,
    timeout=60.0)
```

`ServerRestartResult`は`status / old_listener_id / old_server_id / runtime / reason / request_sent`を返す。
成功時は受付ID不変、新しいserver ID、子の起動確認が必要。古い期待IDによる再送は`id_mismatch`となり、再交換しない。

| status | 意味・次の確認 |
| --- | --- |
| `success` | 子の交換と新子の起動を確認した。 |
| `busy` | 受理していない。今の計算等が終わった後に運用側で判断する。 |
| `id_mismatch` | 照会後に受付または子が変わった。現在のIDを照会する。 |
| `stop_failed` / `startup_failed` | 停止または起動に失敗。受付は利用不可として状態・logを確認する。 |
| `transport_error` | 再起動要求の送信前に通信に失敗した。 |
| `unknown` | 送信後に応答を確認できず、操作済みの可能性がある。要求を自動再送しない。 |

`unknown`なら状態照会だけを行い、同じlistener ID・旧値とは異なるserver ID・`ready=true`を照合する。
旧server IDがidleになっただけでは再起動成功とは判定できない。受付IDまで変わった場合も自動で同一操作の成功としない。

## conductorから全nodeへ指示

対象は、操作を受けたconductorの`SYNCOPADE_NODE_PROFILE`に対応する
[`syncopadeNodeConfig.jl`](../syncopadeNodeConfig.jl)の設定全件。
現在のprofileは`lan12`（既定）と`lan100`。IP/port重複だけをまとめ、開始時に対象一覧を固定する。
`LIST`に表示されたidle nodeだけを選ぶ操作ではない。停止中・到達不能・旧版のnodeも結果に含める。
呼出し元CLIのprofileではなく、**conductor側の設定**が対象を決める。

conductorに待機task、未終端task、割当がある場合は一斉操作全体を拒否し、nodeへの再起動要求を送らない。
受理後は新規SUBMITを`ERROR|BUSY|MAINTENANCE`として拒否し、dispatchを止める。
状態監視・照会は継続する。cache clearと一斉再起動も同時実行しない。

各nodeへの指示は並行に送るが、全nodeが同時刻に切り替わる保証や、部分失敗時の巻戻しはない。

```bash
julia --project=. scripts/restart_conductor_servers.jl CONDUCTOR_IP CONDUCTOR_PORT
# 操作IDを呼出し側で発行・保存して渡す場合
julia --project=. scripts/restart_conductor_servers.jl CONDUCTOR_IP CONDUCTOR_PORT --operation-id OPERATION_UUID
# 接続が切れた後は、表示/保存した同じ操作IDを照会する（再起動は開始しない）
julia --project=. scripts/restart_conductor_servers.jl CONDUCTOR_IP CONDUCTOR_PORT --operation-id OPERATION_UUID --status
```

CLIは最初にoperation IDを表示する。終了codeは全対象成功0、拒否/部分失敗/対象0件2、
通信失敗/記録不明3、待機期限でまだ実行中4、引数誤り64。
`--timeout`はCLIの待機期限（既定90秒）で、計算の打切り時間でも操作の取消しでもない。

```julia
using Syncopade, UUIDs
conductor_ip, conductor_port = "127.0.0.1", 9030  # 実際の対象へ置き換える
operation_id = string(uuid4())  # 開始前にこの値を保存する
receipt = start_conductor_executor_restart(conductor_ip; conductor_port, operation_id)
# 受理済み、または開始応答が不明なときだけ、同じ操作を照会して待つ
if receipt.state in (:running, :outcome_unknown)
    receipt = wait_conductor_executor_restart(conductor_ip; conductor_port, operation_id)
end
# 後から一度だけ確認する場合
status = query_conductor_executor_restart(conductor_ip; conductor_port, operation_id)
```

`ConductorRestartStatus`は`operation_id / state / target_count / completed_count / nodes / summary / reason`を返す。
実行中は`summary=nothing`。完了後にnode別の`ServerRestartResult`と集計を返す。
成功条件は`total_nodes > 0`、`failed_nodes == 0`、`success_nodes == total_nodes`、`overall_success=true`のすべて。
`complete`は集計が終わった意味であり、全体成功とは限らない。

開始元の接続が切れても受理済み操作は継続する。同じoperation IDの再要求は既存の記録を返す。
ただし記録はconductorのメモリ上だけで、conductor再起動後は`unknown`になる。
記録不明を理由に新しい操作IDで再起動し直さず、各受付のIDと状態を確認して対処する。

成否不明のnodeはdispatch対象から隔離する。監視が同じ受付ID・新しい子ID・readyを確認した場合に解除する。
旧子がidleと答えただけでは解除しない。受付IDが変わった場合の自動解除もしない。
完了した操作結果は後から書き換えないため、隔離解除後も元の結果はunknownのまま残る。
conductor再起動では操作記録と隔離情報も失われるため、状態確認前の次batch投入は避ける。

## 起動設定と制御期限

受付と子は同じJulia実行ファイルを使用する。子には受付起動時の有効Project、作業directory、環境変数の写し、
default/interactive thread数を明示する。子は`--startup-file=no`で起動し、アプリpackageを受付へ読み込まない。
再起動はこれらの設定を再利用するため、受付の環境変数を変更したい場合は受付自体の再起動が必要。

| 設定・引数 | 既定秒数 | 対象 |
| --- | ---: | --- |
| `SYNCOPADE_EXECUTOR_STARTUP_TIMEOUT` | 30 | 子の起動応答待ち |
| `SYNCOPADE_EXECUTOR_SHUTDOWN_TIMEOUT` | 10 | 子の停止応答・終了確認（各待機） |
| `SYNCOPADE_EXECUTOR_CLEANUP_TIMEOUT` | 2 | 起動/停止失敗後のTERM/KILL回収（各待機） |
| `SYNCOPADE_EXECUTOR_CACHE_TIMEOUT` | 5 | 子のcache clear応答 |
| `SYNCOPADE_RESTART_QUERY_TIMEOUT` | 5 | conductorから各nodeの状態照会 |
| `SYNCOPADE_RESTART_TIMEOUT` | 60 | conductorから各nodeの再起動応答 |
| 単体API/CLI `timeout` | 60 | 呼出し側の再起動応答待ち |
| 一斉wait API/CLI `timeout` | 90 | 同じoperation IDの照会待機 |

いずれも**計算時間の上限ではない**。50分の計算をこの値で打ち切ることはない。
起動に時間が必要なら起動側と呼出し側の制御期限を合わせて調整する。
送信後のtimeoutは「操作されなかった」の証拠にならない。

子との専用通信はloopbackの動的portを使用し、stdout/stderrとは分離している。
frame上限16 MiB、field数上限4096。起動ID・要求ID・応答種別を照合する。
これは信頼できるローカル子とのprotocolで、暗号化・認証機能ではない。
公開管理commandにも新しい認証は追加していないため、信頼したネットワークだけで公開し、IP/portと対象profileを確認する。

## batchの切替手順

1. 全投入元からの新規投入を止め、conductorと各serverの仕事・結果通知が完了したことを確認する。
2. 利用側のコード/Project/Manifestを対象nodeへ配備する。Syncopadeは配備を代行しない。
3. task関数だけの更新なら従来の全node cache clear結果を確認する。package更新なら計算用Juliaを再起動する。
4. 全対象の成功・ID切替・readyを確認する。失敗/不明が一つでもあれば次batchを開始しない。
5. 利用側で版を識別できる小さな確認を実行し、期待した版を読み込めたことを確認してから次batchを開始する。

一斉操作完了後、conductorの投入制限自体は解除される。部分失敗でも全利用者を恒久的に止める機能ではないので、
上の投入元の停止は利用側で維持する。conductorを経由しない直接投入との一括排他も提供しない。

## サーバ全体を終了するとき

普段の`julia scripts/run_server.jl`または`julia syncopadeServer.jl`で起動する。
引数なしのprofile選択は従来通り。明示指定は`--bind IP --port PORT`（両方必須）。

`q`→Enter、入力終了、Ctrl-Cはいずれも新規受付を止め、計算と結果通知を待ってから子と受付を終了する。
q/入力終了はexit 0、Ctrl-Cで後始末を完了した場合はexit 130。二度目のCtrl-Cも同じ終了依頼へ集約する。
計算が終わらなければ待ち続ける。強制終了や、任意のアプリが作った孫processの回収を保証するものではない。
受付の突然死については、idle子が通信切断を検出して終了することを試験した。

CLIのsignal受信はJulia内蔵libuvを使い、処理の途中へInterruptExceptionを投げ込まない。
子は別process groupで起動し、親からのSTOPで終了させる。
ライブラリとしてincludeするだけではsignal設定を変えず、processも起動しない。
CLI `main`をREPLで使う用途は保証せず、組込み利用では`syncopade_server`と`stop_listener!`で所有する。

## 検証範囲と根拠

今回の試験はJulia 1.12.3/macOS、専用のloopback接続と一時packageによるもの。
同じUUIDのpackageのV1→V2切替、precompile無効時も含む公開経路、2受付+2計算子+conductorの5 process、
BUSY時の投入保持、部分失敗、終了時の結果通知・子回収を確認した。
実MDO最適化、本番LANへの展開、Windows console/Linux/他Julia版の動作確認は含めない。
特にsignal受信にはJulia Baseのevent-loop/I/O-lock helperを使うので、Julia更新時に終了試験も再実行する。
実行方法と試験一覧は[Testing Guide](TESTING.md)、実測記録は[Todo](../TODO_syncopade_listener_executor_restart.md)を参照。

- [Julia code loading](https://docs.julialang.org/en/v1/manual/code-loading/): 同一sessionで読み込み済みpackageが再利用される境界。
- [libuv signal handle](https://docs.libuv.org/en/v1.x/signal.html): signalをevent loopで扱うAPIとOS差。
- [libuv handle lifetime](https://docs.libuv.org/en/v1.x/handle.html): uv_close callbackまではnative handleの記憶領域を保持する。
- [Julia v1.12.3 Cmd](https://github.com/JuliaLang/julia/blob/v1.12.3/base/cmd.jl): detach設定によるprocess group分離。
