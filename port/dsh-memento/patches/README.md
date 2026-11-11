# 本地补丁：client-configforms-softwait

## 现象（实测）
设置页打开 dsh-memento 卡片，顶部显示：

```
Read-only (settings service unavailable).
```

且 Discard / Save 均不可用，整个表单是空的。

## 根因
`client/client.js` 的 `apply(ctx)` 里**一次性**解析设置句柄：

```js
const controller = new MementoCardController(resolveSettingsScope(ctx))
```

`resolveSettingsScope` 依次尝试：
1. `ctx.get('configForms')?.get(entryId)`（0.1.7+ 线）
2. `ctx.get('settingsScope')?.bind(...)`（旧线）
3. 都不在场 → `UNAVAILABLE_SCOPE`

`UNAVAILABLE_SCOPE.getSnapshot()` 返回 `{status:'unavailable', writable:false}`，
于是卡片渲染 `readOnly` 提示；`CardForm.save()` 里
`if (snapshot.status !== 'ready' || !snapshot.writable) return` 直接把保存挡掉。

**为什么那一刻服务没就绪**：`dsh-memento` 的客户端插件声明是 `inject: ['slots']`，
只等 slots。而提供 `configForms` 的是 `@deepseek-ai/dsh-client-ui-settings`，
两者在客户端装配图里是不同节点（实测 index 76 vs 22），`inject` 中没有该依赖
⇒ cordis 不保证 ui-settings 的 `Service` 注册先于 memento 的 `apply` 执行。

上游注释解释了为什么不敢写进 inject：

> 两者都**不写进 inject**：对面那条线的服务在另一侧宿主上永不到场，写进去会让
> fiber 永久 PENDING——整个客户端插件（含只读面板）都不会挂载。缺席即降级为只读。

这个顾虑是对的（旧线上 `configForms` 永不到场），但代价是新线上也退化成只读。

## 修法
不动 `inject` 声明（面板必须无条件挂载），改用 **cordis 软等待**：

```js
ctx.inject(['configForms'], (inner) => {
  const scope = resolveSettingsScope(inner)
  if (!scope || scope === UNAVAILABLE_SCOPE) return
  controller.rebind(scope)
})
```

`ctx.inject(deps, cb)` 是 cordis 的标准延迟初始化入口（核心插件
`dsh-client-ui-approval`、`dsh-client-ui-chat`、`dsh-agent-loop` 等都这么用）：
依赖到场才跑 `cb`，永不到场就永不跑——正好满足「旧线保持只读、新线自动升级为可编辑」。

配套新增两个方法：

- `MementoCardController#rebind(scope)`：用真实句柄重建 `CardForm`，
  清空并重建 `listeners` 里的投影闭包（必须读 `this.form` 而非捕获旧实例），
  再 `store.set(projection())` 让已挂载的订阅者立即拿到新快照。
- `MementoCardController#release()`：幂等释放，由 `inner.effect` 的清理器调用。

## 验证方式
重启应用后打开设置页 → dsh-memento：
- 顶部不再出现 `Read-only (settings service unavailable)`
- 表单字段有值、可编辑
- 改一项 → Save 可点，保存后 `/api/memento/entries` 的 `language` 等字段随之变化

回滚：`cp patches/client.js.orig client/client.js`。
