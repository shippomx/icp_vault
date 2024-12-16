目前IC学习完成了哪些模块？ Motoko语言有哪些显著的不利之处？
**IC学习完成了哪些模块**
1. 学习了视频基础教程，了解了大致架构。学习了一些基本概念： 子网，cycles, canister 容器等。
2. motoko基础语法
	1. let和var的区别，let用于声明不可变量，var声明可变量
	2. object对象和record的区别(关键字public, 是否可以给其它成员变量做初始化)
	3. actor
		- 支持actor之间的相互的异步调用
		- 如果是public函数，必须是 async， 而async函数又是可以shared，shared意思是指，可以将函数作为函数参数传递给其它的actor
		- 在函数内不能直接调用，因为是async即异步的，所以需要使用`await`关键字
		- query类似于solidity的view关键字，表明只是call 并不会 update
		- 升级actor，会导致值丢失。如果需要内部的状态值持久化，需要使用stable关键字进行标识
	1. 其它与rust语言比较类似，有模式匹配，Optional/Result类型返回值，范型等
4. canister 简单使用， 一些示例 https://github.com/dfinity/examples 的学习 
	1. 编译，本地部署
	2. 命令行调用actor函数

**motoko有哪些不利之处**：
1. 作为ICP的专用语言，适用面单一
2. 异步编程模型调试起来会比较麻烦，如是否会存在多个异步调用的相互依赖
3. 调试工具和性能分析工具不足，尤其是在遇到复杂问题或调试异步调用时，可能需要额外的时间排查问题
4. 对存储使用不太方便，存储的值越多，消耗的cycles也越多

### IC Dashboard为每一个canister提供了后端接口界面，这个界面如何做接口安全管理？
- 在 Canister 中维护一个白名单限制用户的访问权限。使用 `msg.caller` 获取调用者的 Principal，并判断是否允许访问。
- 确保canister仅接受通过 II 认证的用户请求进行访问，在 Canister 端验证调用者的 `msg.caller` 是否有效。
- 划分所访问接口的可访问权限
- 其它防御比如验证输入，限制单位时间内的访问次数，使用日志记录关键操作

### 负责出入金的支付中心通常需要有什么安全控制？
- 用户的身份认证，所能访问的接口进行限权
- 用户的关键信息加密存储，密钥需要专门的密钥管理系统管理
- 异常交易进行风控，能够冻结异常资产
- 日志记录方便审计
- 容灾备份

### 请查看 [https://github.com/open-chat-labs/open-chat](https://github.com/open-chat-labs/open-chat) .  Openchat的User模块怎么设计？ 怎么处理用户身份过期？用户邮箱注册生成链上钱包地址用什么机制？为什么要生成用户的principle？

Openchat的User模块怎么设计
- 为每个用户提供自己的容器。
- 容器中保存着用户的直接聊天记录，包括双方的消息、用户所属的每个组的引用以及其他数据，例如他们的身份验证主体、用户名、个人简介、头像和被屏蔽的用户。
- 用户的容器变成了一个钱包，用于在 IC 账本中保存代币，从而允许代币以聊天消息的形式在用户之间发送

怎么处理用户身份过期
- 首先是如何判断？ [If you pass no options to the IdleManager, it will log you out after 10 minutes of inactivity by removing the `DelegationIdentity` from localStorage and then calling `window.location.reload()`.](https://github.com/dfinity/agent-js/blob/main/packages/auth-client/README.md)

- 处理过期用户，从加入的community中移除
```
pub fn remove_user_from_community(
        &mut self,
        user_id: UserId,
        principal: Option<Principal>,
        now: TimestampMillis,
    ) -> Option<CommunityMemberInternal> {
        let removed = self.members.remove(user_id, principal, now);
        self.channels.leave_all_channels(user_id, now);
        self.expiring_members.remove_member(user_id, None);
        self.expiring_member_actions.remove_member(user_id, None);
        self.user_cache.delete(user_id);
        removed
    }

    pub fn remove_user_from_channel(&mut self, user_id: UserId, channel_id: ChannelId, now: TimestampMillis) {
        self.members.mark_member_left_channel(user_id, channel_id, false, now);
        self.expiring_members.remove_member(user_id, Some(channel_id));
        self.expiring_member_actions.remove_member(user_id, Some(channel_id));
    }
```

用户邮箱注册生成链上钱包地址用什么机制？
Internet Identity (II ) 

为什么要生成用户的principle?
生成用户的 principal 通常是为了在分布式系统或区块链应用中，有效地识别和验证用户的身份，并授权其执行特定的操作。

### 如果通过IC random generator 生成种子，现在需要在5万的range生成3000个随机数，用什么方法和代码实现比较好（有什么库可以用）？ 怎么评价他们的效果？

官方文档有这么句话, Using `raw_rand` as seed for a psuedo random number generator (PRNG)
步骤:
- 1 使用`var seed = await Random.blob();` 生成一个新的seed
- 2 在循环中
	- 2.1 使用`let finiteRandom = Random.Finite(seed);`生成伪随机数
	- 2.2 保存这个新的值到预先分配好的组数中
	- 2.3 每次循环结束后, 用生成的伪随机数对`seed`进行改变
- 3 重复上述步骤

如果直接使用`raw_rand`来生成3000个伪随机数, 需要进行3000次异步调用. 如果使用上面的方法, 则可以将生成值作为种子,  快速生成所需要的伪随机数.


### 如果有多个同类型的抽奖产品在运行，用户每抽奖一次扣除1usdt，win获取5usdt，总抽奖次数1000次，中奖率19%,用户可以随时提款。由于服务不稳定，抽奖服务可能被中断。应该建立什么机制防止数据丢失，确保用户的抽奖和win数据，以及提现都划转正确？

- 通常采用锁定机制来确保调用者或任何人一次只能执行一次涉及多条消息的整个调用。
- 可以使用`try`/`finally`控制流保证无论 `try`或块`finally`中是否存在任何错误，锁都会在`try catch`块中释放。
- 使用`journaling`, 是容器存储中按时间顺序排列的记录列表。它跟踪任务开始前和完成时的情况。

