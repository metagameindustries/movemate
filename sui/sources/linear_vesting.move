// SPDX-License-Identifier: MIT

/// @title linear_vesting
/// @dev This contract handles the vesting of coins for a given beneficiary. Custody of multiple coins
/// can be given to this contract, which will release the token to the beneficiary following a given vesting schedule.
/// The vesting schedule is customizable through the {vestedAmount} function.
/// Any token transferred to this contract will follow the vesting schedule as if they were locked from the beginning.
/// Consequently, if the vesting has already started, any amount of tokens sent to this contract will (at least partly)
/// be immediately releasable.
module movemate::linear_vesting {
    use std::errors;
    use std::option::{Self, Option};

    use sui::coin::{Self, Coin};
    use sui::object::{Self, Info};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    /// @dev When trying to clawback a wallet without the privilege to do so.
    const ECANNOT_CLAWBACK: u64 = 0;

    struct Wallet<phantom T> has key {
        info: Info,
        beneficiary: address,
        coin: Coin<T>,
        released: u64,
        start: u64,
        duration: u64,
        clawbacker: Option<address>
    }

    /// @dev Set the beneficiary, start timestamp and vesting duration of the vesting wallet.
    public entry fun init_wallet<T>(beneficiary: address, start: u64, duration: u64, clawbacker: Option<address>, ctx: &mut TxContext) {
        transfer::share_object(Wallet<T> {
            info: object::new(ctx),
            beneficiary,
            coin: coin::zero<T>(ctx),
            released: 0,
            start,
            duration,
            clawbacker
        });
    }

    /// @dev Deposits `coin_in` to `wallet`.
    public fun deposit<T>(wallet: &mut Wallet<T>, coin_in: Coin<T>) {
        coin::join(&mut wallet.coin, coin_in)
    }

    /// @notice Returns the vesting wallet details.
    public fun wallet_info<T>(wallet: &mut Wallet<T>): (address, u64, u64, u64, u64, Option<address>) {
        (wallet.beneficiary, coin::value(&wallet.coin), wallet.released, wallet.start, wallet.duration, wallet.clawbacker)
    }

    /// @dev Release the tokens that have already vested.
    public entry fun release<T>(wallet: &mut Wallet<T>, ctx: &mut TxContext) {
        // Release amount
        let releasable = vested_amount(wallet.start, wallet.duration, coin::value(&wallet.coin), wallet.released, tx_context::epoch(ctx)) - wallet.released;
        *&mut wallet.released = *&wallet.released + releasable;
        coin::split_and_transfer<T>(&mut wallet.coin, releasable, wallet.beneficiary, ctx);
    }

    /// @notice Claws back coins to the `clawbacker` if enabled.
    /// @dev TODO: Clawback capability.
    /// @dev TODO: Destroy wallet.
    public entry fun clawback<T>(wallet: &mut Wallet<T>, ctx: &mut TxContext) {
        // Check clawbacker address
        let sender = tx_context::sender(ctx);
        assert!(option::is_some(&wallet.clawbacker) && sender == *option::borrow(&wallet.clawbacker), errors::requires_address(ECANNOT_CLAWBACK));

        // Release amount
        let releasable = vested_amount(wallet.start, wallet.duration, coin::value(&wallet.coin), wallet.released, tx_context::epoch(ctx)) - wallet.released;
        *&mut wallet.released = *&wallet.released + releasable;
        coin::split_and_transfer<T>(&mut wallet.coin, releasable, wallet.beneficiary, ctx);

        // Execute clawback
        let coin_out = &mut wallet.coin;
        let value = coin::value(coin_out);
        coin::split_and_transfer<T>(coin_out, value, sender, ctx);
    }

    /// @dev Returns (1) the amount that has vested at the current time and the (2) portion of that amount that has not yet been released.
    public fun vesting_status<T>(wallet: &Wallet<T>, ctx: &mut TxContext): (u64, u64) {
        let vested = vested_amount(wallet.start, wallet.duration, coin::value(&wallet.coin), wallet.released, tx_context::epoch(ctx));
        (vested, vested - wallet.released)
    }

    /// Calculates the amount that has already vested. Default implementation is a linear vesting curve.
    fun vested_amount(start: u64, duration: u64, balance: u64, already_released: u64, timestamp: u64): u64 {
        vesting_schedule(start, duration, balance + already_released, timestamp)
    }

    /// @dev Virtual implementation of the vesting formula. This returns the amount vested, as a function of time, for an asset given its total historical allocation.
    fun vesting_schedule(start: u64, duration: u64, total_allocation: u64, timestamp: u64): u64 {
        if (timestamp < start) return 0;
        if (timestamp > start + duration) return total_allocation;
        (total_allocation * (timestamp - start)) / duration
    }

    #[test_only]
    use sui::test_scenario;

    #[test_only]
    const TEST_ADMIN_ADDR: address = @0xA11CE;

    #[test_only]
    const TEST_BENEFICIARY_ADDR: address = @0xB0B;

    #[test_only]
    struct FakeMoney { }

    #[test]
    public entry fun test_end_to_end() {
        // Test scenario
        let scenario = &mut test_scenario::begin(&TEST_ADMIN_ADDR);

        // Mint fake coin
        let coin_in = coin::mint_for_testing<FakeMoney>(1234567890, test_scenario::ctx(scenario));

        // init wallet and asset
        init_wallet<FakeMoney>(TEST_BENEFICIARY_ADDR, tx_context::epoch(test_scenario::ctx(scenario)), 7, option::some(TEST_ADMIN_ADDR), test_scenario::ctx(scenario));
        test_scenario::next_tx(scenario, &TEST_ADMIN_ADDR);
        let wallet_wrapper = test_scenario::take_shared<Wallet<FakeMoney>>(scenario);
        let wallet = test_scenario::borrow_mut(&mut wallet_wrapper);
        deposit<FakeMoney>(wallet, coin_in);

        // fast forward and release
        test_scenario::next_epoch(scenario);
        test_scenario::next_epoch(scenario);
        release<FakeMoney>(wallet, test_scenario::ctx(scenario));
        test_scenario::return_shared(scenario, wallet_wrapper);

        // Ensure release worked as planned
        test_scenario::next_tx(scenario, &TEST_BENEFICIARY_ADDR);
        let beneficiary_coin = test_scenario::take_owned<Coin<FakeMoney>>(scenario);
        assert!(coin::value<FakeMoney>(&beneficiary_coin) == 352733682, 0);
        test_scenario::return_owned(scenario, beneficiary_coin);

        // fast forward and claw back vesting
        test_scenario::next_tx(scenario, &TEST_ADMIN_ADDR);
        test_scenario::next_epoch(scenario);
        test_scenario::next_epoch(scenario);
        test_scenario::next_epoch(scenario);
        let wallet_wrapper = test_scenario::take_shared<Wallet<FakeMoney>>(scenario);
        let wallet = test_scenario::borrow_mut(&mut wallet_wrapper);
        clawback<FakeMoney>(wallet, test_scenario::ctx(scenario));
        test_scenario::return_shared(scenario, wallet_wrapper);

        // Ensure clawback worked as planned
        test_scenario::next_tx(scenario, &TEST_BENEFICIARY_ADDR);
        let beneficiary_coin = test_scenario::take_last_created_owned<Coin<FakeMoney>>(scenario);
        assert!(coin::value<FakeMoney>(&beneficiary_coin) == 881834207 - 352733682, 1);
        test_scenario::return_owned(scenario, beneficiary_coin);
        test_scenario::next_tx(scenario, &TEST_ADMIN_ADDR);
        let admin_coin = test_scenario::take_owned<Coin<FakeMoney>>(scenario);
        assert!(coin::value<FakeMoney>(&admin_coin) == 1234567890 - 881834207, 2);
        test_scenario::return_owned(scenario, admin_coin);
    }

    #[test]
    #[expected_failure(abort_code = 0x002)]
    public entry fun test_no_clawback() {
        // Test scenario
        let scenario = &mut test_scenario::begin(&TEST_ADMIN_ADDR);

        // Mint fake coin
        let coin_in = coin::mint_for_testing<FakeMoney>(1234567890, test_scenario::ctx(scenario));

        // init wallet and asset
        init_wallet<FakeMoney>(TEST_BENEFICIARY_ADDR, tx_context::epoch(test_scenario::ctx(scenario)), 7, option::none(), test_scenario::ctx(scenario));
        test_scenario::next_tx(scenario, &TEST_ADMIN_ADDR);
        let wallet_wrapper = test_scenario::take_shared<Wallet<FakeMoney>>(scenario);
        let wallet = test_scenario::borrow_mut(&mut wallet_wrapper);
        deposit<FakeMoney>(wallet, coin_in);

        // fast forward and claw back (should fail)
        test_scenario::next_epoch(scenario);
        test_scenario::next_epoch(scenario);
        clawback<FakeMoney>(wallet, test_scenario::ctx(scenario));

        // clean up: return shared wallet object
        test_scenario::return_shared(scenario, wallet_wrapper);
    }
}
