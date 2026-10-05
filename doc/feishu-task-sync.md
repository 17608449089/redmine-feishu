# Redmine → 飞书任务同步

单向同步：Redmine 公开问题的创建、更新、删除会写入飞书任务。飞书侧改动不会回写 Redmine。

镜像：`redmine-feishu:latest`（SQLite，数据在 Docker volume 里，换镜像不会丢账号和问题）。

---

## 行为说明

| Redmine | 飞书任务 |
| --- | --- |
| 新建问题 | 创建任务 |
| 改标题 / 描述 / 状态 / 日期 / 指派人 | 更新任务 |
| 关闭问题 | 标记任务完成 |
| 重新打开 | 取消完成 |
| 删除问题，或改成私有 | 删除飞书任务 |
| 私有问题 | 不同步 |

飞书任务标题：`#12 [进行中] 登录问题`  
飞书任务正文第一行是状态，后面是问题描述。  
开始日期、截止日期会同步。关闭状态会同步为任务完成时间。

成员：

1. 指派人邮箱能匹配到飞书用户时，加入该用户。
2. 管理后台填写的默认 `open_id`（可多个）也会加入，保证任务在「我的任务」里可见。

应用身份创建的任务，如果没有任何成员，飞书里几乎看不到。

---

## 飞书应用准备

在 [飞书开放平台](https://open.feishu.cn/) 创建企业自建应用，开通并发布：

- `task:task:write`（创建 / 更新 / 删除任务、加人）
- `contact:user.id:readonly`（用邮箱查 `open_id`，可选；没有邮箱就靠默认 open_id）

记下 **App ID**、**App Secret**。

查自己的 `open_id`：开放平台 → API 调试台 → 选已授权应用 → 调通讯录相关接口，结果里形如 `ou_xxxx`。

---

## 替换生产镜像（保留原数据）

镜像必须是 **linux/amd64**（生产机是 x86，不能用 Mac ARM 打的包）。本地导出：`~/Downloads/redmine-feishu.tar.gz`。

1. 上传到服务器。
2. 加载镜像：

```bash
docker load < redmine-feishu.tar.gz
```

3. 改 compose，**只换镜像名**。volume 路径、volume 名字、`REDMINE_SECRET_KEY_BASE` 必须和原来一致。原来的 `REDMINE_DB_SQLITE: redmine.sqlite3` 可以留着：官方镜像本来就不读这个变量，真正的库文件一直是 `sqlite/redmine.db`。

```yaml
services:
  redmine:
    image: redmine-feishu:latest
    container_name: redmine-app
    restart: always
    ports:
      - "12323:3000"
    environment:
      REDMINE_DB_SQLITE: redmine.sqlite3
      REDMINE_SECRET_KEY_BASE: <和生产原来相同>
    volumes:
      - redmine_sqlite_data:/usr/src/redmine/sqlite
      - redmine_files_data:/usr/src/redmine/files

volumes:
  redmine_sqlite_data:
  redmine_files_data:
```

官方镜像默认库文件是 `sqlite/redmine.db`。本镜像与之一致。若误连到 `redmine.sqlite3`，会新建空库，看起来像数据丢了（`redmine.db` 仍在 volume 里）。

4. 启动：

```bash
docker compose up -d
```

启动时会自动跑迁移，只新增两张空表（问题 ↔ 飞书任务、用户 ↔ open_id），不会清空用户和 Issue。

可选环境变量（会写入容器内 `configuration.yml`，优先级高于后台设置）：

- `FEISHU_APP_ID`
- `FEISHU_APP_SECRET`
- `FEISHU_API_BASE`（默认 `https://open.feishu.cn`）

本机构建：

```bash
docker compose build
docker save redmine-feishu:latest | gzip > redmine-feishu.tar.gz
```

compose 已固定 `platform: linux/amd64`，在 Apple Silicon 上构建也能给 x86 服务器用。

---

## 后台配置

用管理员登录。

### 1. 全局开关

**管理 → 设置 → 集成**

- 勾选「启用飞书任务同步」
- 填写 App ID、App Secret（若未用环境变量）
- 开放平台地址一般保持 `https://open.feishu.cn`
- **默认飞书用户 open_id**：可填多个，逗号、空格或换行分隔，例如：

```
ou_aaa
ou_bbb, ou_ccc
```

这些人会作为任务成员加入。指派人没有飞书邮箱时，也用这份列表。

保存即可，不必重启。

### 2. 项目模块

每个要同步的项目：**设置 → 模块 → 勾选「飞书任务同步」→ 保存**。

全局开关和项目模块都开，公开问题才会同步。已有问题不会批量补同步，下次编辑该问题才会写入飞书。

---

## 使用

在已开模块的项目里正常建问题、改状态、改描述即可。到飞书「任务」里看对应任务。

建议至少填一个自己的 `open_id`，否则任务可能创建成功但界面找不到。

---

## 本次改动文件（相对原版 Redmine）

同步逻辑：

- `lib/redmine/feishu.rb`
- `lib/redmine/feishu/client.rb`
- `lib/redmine/feishu/task_sync.rb`
- `app/jobs/feishu_task_sync_job.rb`
- `app/models/concerns/issue/feishu_syncable.rb`
- `app/models/feishu_task_mapping.rb`
- `app/models/feishu_user_mapping.rb`
- `db/migrate/20261005040000_create_feishu_sync_tables.rb`
- `db/migrate/20261005073000_widen_feishu_assignee_open_id.rb`

配置与界面：

- `config/settings.yml`、`config/locales/en.yml`、`config/locales/zh.yml`
- `config/configuration.yml.example`
- `app/views/settings/_feishu.html.erb`、`app/views/settings/_api.html.erb`
- `lib/redmine/preparation.rb`、`app/models/issue.rb`

Docker：

- `Dockerfile`、`docker-compose.yml`、`.dockerignore`
- `docker/entrypoint.sh`、`docker/database.yml`、`docker/Gemfile.local`
- `config/puma.rb`

测试：

- `test/unit/lib/redmine/feishu/task_sync_test.rb`
- `test/unit/jobs/feishu_task_sync_job_test.rb`

---

## 排查

同步失败会写容器日志，不阻断保存问题：

```bash
docker logs -f redmine-app
```

常见情况：

| 现象 | 处理 |
| --- | --- |
| 完全没有飞书任务 | 全局开关、项目模块是否都开；问题是否私有 |
| 日志成功但飞书看不到 | 默认 open_id 未填或填错；应用权限未发布 |
| 邮箱对不上 | 飞书账号无邮箱时必须填默认 open_id |
| 换镜像后登不上 | `REDMINE_SECRET_KEY_BASE` 或 sqlite volume 被改掉了 |
