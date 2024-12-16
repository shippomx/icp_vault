import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Option "mo:base/Option";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import TrieMap "mo:base/TrieMap";
import Nat64 "mo:base/Nat64";

// Import our ICRC type definitions
import ICRC "./ICRC";

// The vault canister is the main backend canister for this example. To simplify
// this example we configure the vault canister with the two tokens it will be
// swapping.
shared (init_msg) actor class Vault(
  init_args : {
    token : Principal;
  }
) = this {

  let SECOND : Nat64 = 1_000_000_000; 
  let FROZEN_SECONDS : Nat64 = 3600*120*SECOND; // assume 5 days

  // Track the deposited per-user balances for token
  public type Deposit = {
    balance : Nat;
    acc_reward : Nat;
    updated_at: Nat64;
  };
  private var deposits = TrieMap.TrieMap<Principal, Deposit>(Principal.equal, Principal.hash);

  // balances is a simple getter to check the balances of all users, to make debugging easier.
  public query func balancesAll() : async ([(Principal, Deposit)]) {
    (Iter.toArray(deposits.entries()));
  };

  public type DepositArgs = {
    spender_subaccount : ?Blob;
    token : Principal;
    from : ICRC.Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type DepositError = {
    #TransferFromError : ICRC.TransferFromError;
  };

  // Accept deposits
  // - user approves transfer: `token.icrc2_approve({ spender=vault_canister; amount=amount; ... })`
  // - user deposits their token: `vault_canister.deposit({ token=token; amount=amount; ... })`
  // - These deposit handlers show how to safely accept and register deposits of an ICRC-2 token.
  public shared (msg) func deposit(args : DepositArgs) : async Result.Result<Nat, DepositError> {
    let sender = args.from.owner;
    let token : ICRC.Actor = actor (Principal.toText(args.token));
    let _deposits = which_deposits(args.token);
    let _deposit = Option.get(_deposits.get(msg.caller),
       {balance = 0; acc_reward = 0; updated_at = 0}: Deposit
    );

    // Load the fee from the token here. The user can pass a null fee, which
    // means "use the default". So we need to look up the default in order to
    // correctly deduct it from their balance.
    let fee = switch (args.fee) {
      case (?f) { f };
      case (null) { await token.icrc1_fee() };
    };

    // Perform the transfer, to capture the tokens.
    let transfer_result = await token.icrc2_transfer_from({
      spender_subaccount = args.spender_subaccount;
      from = args.from;
      to = { owner = Principal.fromActor(this); subaccount = null };
      amount = args.amount;
      fee = ?fee;
      memo = args.memo;
      created_at_time = args.created_at_time;
    });

    // Check that the transfer was successful.
    let block_height = switch (transfer_result) {
      case (#Ok(block_height)) { block_height };
      case (#Err(err)) {
        // Transfer failed. There's no cleanup for us to do since no state has
        // changed, so we can just wrap and return the error to the frontend.
        return #err(#TransferFromError(err));
      };
    };

    let created_at_time : Nat64 = Option.get(args.created_at_time, 0 : Nat64);

    // From here on out, we need to make sure that this function does *not*
    // fail. If it failed, the token transfer would be complete (meaning we
    // would have the user's tokens), but we would not have credited their
    // account yet, so this canister would not *know* that it had received the
    // user's tokens.
    //
    // If the function *can* fail here after this point, we should either:
    // - Move that code to a separate action later
    // - Have failure-handling code which refunds the user's tokens

    let _reward = _deposit.acc_reward + Nat64.toNat(created_at_time - _deposit.updated_at)*_deposit.balance/1000;
    let new_balance : Nat = _deposit.balance + args.amount;
    deposits.put(sender, {
      balance = new_balance;
      acc_reward = _reward;
      updated_at = created_at_time;
    });

    // Return the "block height" of the transfer
    #ok(block_height);
  };

  public type WithdrawArgs = {
    token : Principal;
    to : ICRC.Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
    is_force: Bool;
  };

  public type WithdrawError = {
    // The caller doesn't not have sufficient funds deposited in this vault
    // contract to fulfil this withdrawal. Note, this is different from the
    // TransferError(InsufficientFunds), which would indicate that this
    // canister doesn't have enough funds to fulfil the withdrawal (a much more
    // serious error).
    #InsufficientFunds : { balance : ICRC.Tokens };
    // For other transfer errors, we can just wrap and return them.
    #TransferError : ICRC.TransferError;
    // 
    #FrozenFunds: { wait: Nat64 };
  };

  // Allow withdrawals
  // - Allow users to withdraw any tokens they hold.
  // - These withdrawal handlers show how to safely send outbound transfers of an ICRC-1 token.
  public shared (msg) func withdraw(args : WithdrawArgs) : async Result.Result<Nat, WithdrawError> {
    let token : ICRC.Actor = actor (Principal.toText(args.token));
    // Load the fee from the token here. The user can pass a null fee, which
    // means "use the default". So we need to look up the default in order to
    // correctly deduct it from their balance.
    let fee = switch (args.fee) {
      case (?f) { f };
      case (null) { await token.icrc1_fee() };
    };

    // Check the user's balance is sufficient
    let _deposits = which_deposits(args.token);
    let _deposit = Option.get(deposits.get(msg.caller),
       {balance = 0; acc_reward = 0; updated_at = 0}: Deposit
    );
    if (_deposit.balance < args.amount + fee) {
      return #err(#InsufficientFunds { balance = _deposit.balance });
    };

    let created_at_time : Nat64 = Option.get(args.created_at_time, 0 : Nat64);

    if (not args.is_force and _deposit.updated_at + FROZEN_SECONDS < created_at_time) {
      return #err(#FrozenFunds { wait = created_at_time - _deposit.updated_at});
    };

    // Debit the sender's account
    //
    // We do this first, due to the asynchronous nature of the IC. By debitting
    // the account first, we ensure that the user cannot withdraw more than
    // they have.
    //
    // If we were to perform the transfer, then debit the user's account, there
    // are several ways which that attack could lead to loss of funds. For
    // example:
    // - The user could call `withdraw` repeatedly, in a DOS attack to trigger
    // a race condition. This would queue multiple outbound transfers in
    // parallel, resulting in the user withdrawing more funds than available.
    // - The token could perform a "reentrancy" attack, where the token's
    // implementation of `icrc1_transfer` calls back into this canister, and
    // triggers another recursive withdrawal, resulting in draining of this
    // canister's token balance. However, because the token canister directly
    // controls user's balances anyway, it could simplify this attack, and just
    // change the canister's balance. Generally, this is why you should only
    // use token canisters which you trust and can review.
    let new_balance = if (args.is_force) {
      // take args.amount/10 as penalty
      _deposit.balance - args.amount*9/10 - fee;
    } else {
      _deposit.balance - args.amount - fee;
    };
    if (new_balance == 0 and _deposit.acc_reward == 0) {
      // Delete zero-balances to keep the balance table tidy.
      deposits.delete(msg.caller);
    } else {
      deposits.put(msg.caller, {
        balance = new_balance;
        acc_reward = _deposit.acc_reward;
        updated_at = created_at_time;
      });
    };

    // Perform the transfer, to send the tokens.
    let transfer_result = await token.icrc1_transfer({
      from_subaccount = null;
      to = args.to;
      amount = if (args.is_force) {args.amount*9/10;} else {args.amount;};
      fee = ?fee;
      memo = args.memo;
      created_at_time = args.created_at_time;
    });

    // Check that the transfer was successful.
    let block_height = switch (transfer_result) {
      case (#Ok(block_height)) { block_height };
      case (#Err(err)) {
        // The transfer failed, we need to refund the user's account (less
        // fees), so that they do not completely lose their tokens, and can
        // retry the withdrawal.
        //
        // Refund the user's account. Note, we can't just put the old_balance
        // back, because their balance may have changed simultaneously while we
        // were waiting for the transaction.
        deposits.put(msg.caller, {
          balance = _deposit.balance;
          acc_reward = _deposit.acc_reward;
          updated_at = created_at_time;
        });

        return #err(#TransferError(err));
      };
    };

    // Return the "block height" of the transfer
    #ok(block_height);
  };

  public type ReclaimRewardArgs = {
    token : Principal;
    to : ICRC.Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type ReclaimRewardError = {
    #InsufficientReward : { balance : ICRC.Tokens };
    // For other transfer errors, we can just wrap and return them.
    #TransferError : ICRC.TransferError;
  };

  public shared (msg) func reclaimReward(args : ReclaimRewardArgs) : async Result.Result<Nat, ReclaimRewardError> {
    let token : ICRC.Actor = actor (Principal.toText(args.token));
    let _deposits = which_deposits(args.token);

    // Load the fee from the token here. The user can pass a null fee, which
    // means "use the default". So we need to look up the default in order to
    // correctly deduct it from their balance.
    let fee = switch (args.fee) {
      case (?f) { f };
      case (null) { await token.icrc1_fee() };
    };

    // Check the user's balance is sufficient
    let _deposit = Option.get(_deposits.get(msg.caller),
       {balance = 0; acc_reward = 0; updated_at = 0}: Deposit
    );
    if (_deposit.balance < args.amount + fee) {
      return #err(#InsufficientReward { balance = _deposit.acc_reward});
    };

    let created_at_time : Nat64 = Option.get(args.created_at_time, 0 : Nat64);

    let new_reward = _deposit.acc_reward - args.amount - fee;
    if (new_reward == 0 and _deposit.balance == 0) {
      // Delete zero-balances to keep the balance table tidy.
      deposits.delete(msg.caller);
    } else {
      deposits.put(msg.caller, {
        balance = _deposit.balance;
        acc_reward = new_reward;
        updated_at = created_at_time;
      });
    };

    // Perform the transfer, to send the tokens.
    let transfer_result = await token.icrc1_transfer({
      from_subaccount = null;
      to = args.to;
      amount = args.amount;
      fee = ?fee;
      memo = args.memo;
      created_at_time = args.created_at_time;
    });

    // Check that the transfer was successful.
    let block_height = switch (transfer_result) {
      case (#Ok(block_height)) { block_height };
      case (#Err(err)) {
        // The transfer failed, we need to refund the user's account (less
        // fees), so that they do not completely lose their tokens, and can
        // retry the withdrawal.
        //
        // Refund the user's account. Note, we can't just put the old_balance
        // back, because their balance may have changed simultaneously while we
        // were waiting for the transaction.
        deposits.put(msg.caller, {
          balance = _deposit.balance;
          acc_reward = _deposit.acc_reward;
          updated_at = created_at_time;
        });

        return #err(#TransferError(err));
      };
    };

    // Return the "block height" of the transfer
    #ok(block_height);
  };

  // which_deposits checks which token we are withdrawing, and configure the
  // rest of the transfer. This function will assert that the token specified
  // must be either token_a, or token_b.
  private func which_deposits(t : Principal) : TrieMap.TrieMap<Principal, Deposit> {
    let _reward = if (t == init_args.token) {
      deposits;
    } else {
      Debug.trap("invalid token canister");
    };
  };

};
