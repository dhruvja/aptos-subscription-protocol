module Subscription::subscription {

    use std::signer;

    use aptos_framework::timestamp;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::managed_coin;
    use aptos_framework::aptos_account;

    use aptos_std::ed25519;

    const EMERCHANT_AUTHORITY_ALREADY_CREATED: u64 = 0;
    const EMERCHANT_AUTHORITY_NOT_CREATED: u64 = 1;
    const EPAYMENT_CONFIG_ALREADY_CREATED: u64 = 2;
    const EPAYMENT_CONFIG_NOT_CREATED: u64 = 3;
    const ETIME_INTERVAL_NOT_ELAPSED: u64 = 4;
    const EINVALID_MERCHANT_AUTHORITY: u64 = 5;
    const ELOW_DELEGATED_AMOUNT: u64 = 6;
    const ESUBSCRIPTION_IS_INACTIVE: u64 = 7;
    const EALREADY_ACTIVE: u64 = 8;
    const EINVALID_BALANCE: u64 = 9;
    const EPAYMENT_METADATA_NOT_CREATED: u64 = 10;
    const EPAYMENT_METADATA_IS_STILL_ACTIVE: u64 = 11;
    const ENOT_ACTIVE: u64 = 12;

    struct MerchantAuthority has key {
        init_authority: address,
        current_authority: address,
    } 

    struct PaymentConfig<phantom CoinType> has key {
        payment_account: address,
        merchant_authority: address,
        collect_on_init: bool,
        amount_to_collect_on_init: u64,
        amount_to_collect_per_period: u64, // in seconds
        time_interval: u64,
        subscription_name: vector<u8>,
    }

    struct PaymentMetadata<phantom CoinType> has key {
        owner: address,
        created_at: u64, // timestamp in seconds
        payment_config: address,
        amount_delegated: u64,
        payments_collected: u64,
        pending_delegated_amount: u64,
        resource_signer_cap: account::SignerCapability,
        last_payment_collection_time: u64, // timestamp in seconds
        active: bool
    }

    public entry fun initialize_merchant_authority(merchant: &signer) {
        let merchant_addr = signer::address_of(merchant);
        assert!(!exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_ALREADY_CREATED);

        move_to<MerchantAuthority>(merchant, MerchantAuthority{
            init_authority: merchant_addr,
            current_authority: merchant_addr
        });
    }

    public entry fun initialize_payment_config<CoinType>(merchant: &signer, payment_account: address, collect_on_init: bool, amount_to_collect_on_init: u64, amount_to_collect_per_period: u64, time_interval: u64, subscription_name: vector<u8>) {
        let merchant_addr = signer::address_of(merchant);
        assert!(exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_NOT_CREATED);
        assert!(!exists<PaymentConfig<CoinType>>(merchant_addr), EPAYMENT_CONFIG_ALREADY_CREATED);

        let payment_config = PaymentConfig {
            payment_account,
            merchant_authority: merchant_addr,
            collect_on_init,
            amount_to_collect_on_init,
            amount_to_collect_per_period,
            time_interval,
            subscription_name
        };
        move_to<PaymentConfig<CoinType>>(merchant, payment_config);
    }

    public entry fun initialize_payment_metadata<CoinType>(subscriber: &signer, merchant_addr: address, cycles: u64, signer_capability_sig_bytes: vector<u8>, account_public_key_bytes: vector<u8>) acquires PaymentConfig {
        let subscriber_addr = signer::address_of(subscriber);
        assert!(exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_NOT_CREATED);
        assert!(exists<PaymentConfig<CoinType>>(merchant_addr), EPAYMENT_CONFIG_NOT_CREATED);

        let payment_config = borrow_global<PaymentConfig<CoinType>>(merchant_addr);

        let current_time = timestamp::now_seconds();
        let amount_delegated = cycles * payment_config.amount_to_collect_per_period;

        // delegating the account to a resource account
        let (delegated_resource, delegated_resource_cap) = account::create_resource_account(subscriber, payment_config.subscription_name);
        let delegated_addr = signer::address_of(&delegated_resource);
        account::offer_signer_capability(subscriber, signer_capability_sig_bytes, 0, account_public_key_bytes, delegated_addr);

        if (payment_config.collect_on_init) {
            coin::transfer<CoinType>(subscriber, payment_config.payment_account, payment_config.amount_to_collect_on_init);
        };

        let payment_metadata = PaymentMetadata {
            owner: subscriber_addr,
            created_at: current_time,
            payment_config: merchant_addr,
            amount_delegated,
            payments_collected: 0,
            pending_delegated_amount: amount_delegated,
            resource_signer_cap: delegated_resource_cap,
            last_payment_collection_time: 0,
            active: true
        };
        move_to<PaymentMetadata<CoinType>>(subscriber, payment_metadata);
    }

    public entry fun collect_payment<CoinType>(merchant: &signer, customer: address) acquires PaymentConfig, PaymentMetadata {
        let merchant_addr = signer::address_of(merchant);
        let payment_config = borrow_global<PaymentConfig<CoinType>>(merchant_addr);
        let payment_metadata = borrow_global_mut<PaymentMetadata<CoinType>>(customer);
        assert!(payment_metadata.payment_config == merchant_addr, EINVALID_MERCHANT_AUTHORITY);
        assert!(payment_metadata.active, ESUBSCRIPTION_IS_INACTIVE);

        let current_time = timestamp::now_seconds();
        assert!(current_time > (payment_metadata.last_payment_collection_time + payment_config.time_interval), ETIME_INTERVAL_NOT_ELAPSED);
        assert!(payment_metadata.pending_delegated_amount >= payment_config.amount_to_collect_per_period, ELOW_DELEGATED_AMOUNT);

        // derive the resource address using the capability
        let delegated_account = account::create_signer_with_capability(&payment_metadata.resource_signer_cap);
        let delegated_signer = account::create_authorized_signer(&delegated_account, customer);

        // Transfer the amount to merchant account
        coin::transfer<CoinType>(&delegated_signer, payment_config.payment_account, payment_config.amount_to_collect_per_period);

        // Subtract the amount debited from pending delegated amount
        payment_metadata.pending_delegated_amount = payment_metadata.pending_delegated_amount - payment_config.amount_to_collect_per_period;
        payment_metadata.last_payment_collection_time = timestamp::now_seconds();
        payment_metadata.payments_collected = payment_metadata.payments_collected + payment_config.amount_to_collect_per_period;
    }

    public entry fun recharge_subscription<CoinType>(subscriber: &signer, merchant: address, cycles: u64) acquires PaymentConfig, PaymentMetadata {
        let subscriber_addr = signer::address_of(subscriber);
        let payment_config = borrow_global<PaymentConfig<CoinType>>(merchant);
        let payment_metadata = borrow_global_mut<PaymentMetadata<CoinType>>(subscriber_addr);
        assert!(payment_metadata.payment_config == merchant, EINVALID_MERCHANT_AUTHORITY); 
        assert!(payment_metadata.active, ENOT_ACTIVE);

        let amount_delegated = cycles * payment_config.amount_to_collect_per_period;
        payment_metadata.amount_delegated = payment_metadata.amount_delegated + amount_delegated;
        payment_metadata.pending_delegated_amount = payment_metadata.pending_delegated_amount + amount_delegated; 
    }

    public entry fun revoke_subscription<CoinType>(subscriber: &signer, merchant: address) acquires PaymentMetadata {
        let subscriber_addr = signer::address_of(subscriber);
        let payment_metadata = borrow_global_mut<PaymentMetadata<CoinType>>(subscriber_addr);
        assert!(payment_metadata.payment_config == merchant, EINVALID_MERCHANT_AUTHORITY); 

        // fetching the resource account from capability
        let delegated_address = account::get_signer_capability_address(&payment_metadata.resource_signer_cap);

        // Revoking the signer capability
        account::revoke_signer_capability(subscriber, delegated_address);

        // making the status as inactive
        payment_metadata.active = false;

        // making delegated amount is total delegated amount - pending delegated amount since the rest would be 0
        payment_metadata.amount_delegated = payment_metadata.amount_delegated - payment_metadata.pending_delegated_amount;

        // making pending delegated amount as 0
        payment_metadata.pending_delegated_amount = 0;
    }

    public entry fun activate_subscription<CoinType>(subscriber: &signer, merchant: address, cycles: u64, signer_capability_sig_bytes: vector<u8>, account_public_key_bytes: vector<u8>) acquires PaymentConfig, PaymentMetadata {
        let subscriber_addr = signer::address_of(subscriber);
        let payment_config = borrow_global<PaymentConfig<CoinType>>(merchant);
        let payment_metadata = borrow_global_mut<PaymentMetadata<CoinType>>(subscriber_addr);
        assert!(payment_metadata.payment_config == merchant, EINVALID_MERCHANT_AUTHORITY); 
        assert!(!payment_metadata.active, EALREADY_ACTIVE);
        // offer signer capability to the resource account and activate subscription
        let delegated_address = account::get_signer_capability_address(&payment_metadata.resource_signer_cap); 
        account::offer_signer_capability(subscriber, signer_capability_sig_bytes, 0, account_public_key_bytes, delegated_address);
        payment_metadata.active = true;

        let amount_delegated = cycles * payment_config.amount_to_collect_per_period;
        payment_metadata.amount_delegated = payment_metadata.amount_delegated + amount_delegated;
        payment_metadata.pending_delegated_amount = amount_delegated;
    }

    public entry fun close_subscription<CoinType>(subscriber: &signer, merchant: address) acquires PaymentMetadata {
        let subscriber_addr = signer::address_of(subscriber);
        let payment_metadata = borrow_global_mut<PaymentMetadata<CoinType>>(subscriber_addr);
        assert!(payment_metadata.payment_config == merchant, EINVALID_MERCHANT_AUTHORITY); 

        // fetching the resource account from capability
        let delegated_address = account::get_signer_capability_address(&payment_metadata.resource_signer_cap);

        // Revoking the signer capability
        account::revoke_signer_capability(subscriber, delegated_address);

        // making the status as inactive
        payment_metadata.active = false;

        // making delegated amount is total delegated amount - pending delegated amount since the rest would be 0
        payment_metadata.amount_delegated = payment_metadata.amount_delegated - payment_metadata.pending_delegated_amount;

        // making pending delegated amount as 0
        payment_metadata.pending_delegated_amount = 0; 

        // The resource is moved from the subscriber and destroyed
        let destroy_payment_metadata = move_from<PaymentMetadata<CoinType>>(subscriber_addr);
        let PaymentMetadata {
            owner: _,
            created_at: _, 
            payment_config: _,
            amount_delegated: _,
            payments_collected: _,
            pending_delegated_amount: _,
            resource_signer_cap: _,
            last_payment_collection_time: _,
            active: _ 
        } = destroy_payment_metadata;
    }

    // Tests
    #[test_only]
    struct FakeCoin{}

    #[test_only]
    public fun initialize_coin_and_mint(admin: &signer, user: &signer, mint_amount: u64) {
        let user_addr = signer::address_of(user);
        managed_coin::initialize<FakeCoin>(admin, b"fake", b"F", 9, false);
        managed_coin::register<FakeCoin>(user);
        managed_coin::mint<FakeCoin>(admin, user_addr, mint_amount); 
    }

    #[test_only]
    struct Constant has drop {
        initial_mint_amount: u64,
        collect_on_init: bool,
        amount_to_collect_on_init: u64,
        amount_to_collect_per_period: u64, // in seconds
        time_interval: u64,
        subscription_name: vector<u8>,
        cycles: u64
    }

    #[test_only]
    public fun get_constants() :Constant {
        let constants = Constant {
            initial_mint_amount: 1000000,
            collect_on_init: true,
            amount_to_collect_on_init: 1000,
            amount_to_collect_per_period: 500, // in seconds
            time_interval: 10,
            subscription_name: b"test plan",
            cycles: 4
        };
        return constants
    }
    
    #[test_only]
    fun create_account_and_sign_challenge(subscription_name: vector<u8>) :(vector<u8>, signer, vector<u8>, address) {
        let (customer_sk, customer_pk) = ed25519::generate_keys();
        let customer_pk_bytes = ed25519::validated_public_key_to_bytes(&customer_pk);
        let customer = account::create_account_from_ed25519_public_key(customer_pk_bytes);
        let customer_addr = signer::address_of(&customer); 
        let resource_addr = account::create_resource_address(&customer_addr, subscription_name);

        let challenge = account::get_signer_capability_offer_proof_challenge_V2(customer_addr, resource_addr);
        let customer_signer_capability_offer_sig = ed25519::sign_struct(&customer_sk, challenge);
        let customer_signer_capability_offer_bytes = ed25519::signature_to_bytes(&customer_signer_capability_offer_sig); 
        (customer_pk_bytes, customer, customer_signer_capability_offer_bytes, resource_addr)
    }

    #[test(module_owner= @Subscription, merchant= @0x5, aptos_framework = @0x1 )]
    public fun end_to_end_subscription_success(module_owner: signer, merchant: signer, aptos_framework: signer) acquires PaymentConfig, PaymentMetadata {
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let constants = get_constants();
        let (customer_pk_bytes, customer, customer_signer_capability_offer_bytes, _delegated_resource) = create_account_and_sign_challenge(constants.subscription_name);

        let merchant_addr = signer::address_of(&merchant);
        let customer_addr = signer::address_of(&customer);
        
        initialize_coin_and_mint(&module_owner, &customer, constants.initial_mint_amount);
        assert!(coin::balance<FakeCoin>(customer_addr) == constants.initial_mint_amount, EINVALID_BALANCE);
        aptos_account::create_account(merchant_addr);
        managed_coin::register<FakeCoin>(&merchant);

        initialize_merchant_authority(&merchant);
        assert!(exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_NOT_CREATED);

        initialize_payment_config<FakeCoin>(&merchant, merchant_addr, constants.collect_on_init, constants.amount_to_collect_on_init, constants.amount_to_collect_per_period, constants.time_interval, constants.subscription_name);
        assert!(exists<PaymentConfig<FakeCoin>>(merchant_addr), EPAYMENT_CONFIG_NOT_CREATED);

        initialize_payment_metadata<FakeCoin>(&customer, merchant_addr, constants.cycles, customer_signer_capability_offer_bytes, customer_pk_bytes);
        assert!(exists<PaymentMetadata<FakeCoin>>(customer_addr), EPAYMENT_METADATA_NOT_CREATED);
        assert!(coin::balance<FakeCoin>(merchant_addr) == constants.amount_to_collect_on_init, EINVALID_BALANCE);
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + constants.amount_to_collect_per_period), EINVALID_BALANCE);
        // Collecting for second cycle
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + 2 * constants.amount_to_collect_per_period), EINVALID_BALANCE);
        // Revoking and activating subscription by revoking and offering the delegation respectively.
        revoke_subscription<FakeCoin>(&customer, merchant_addr);
        let payment_metadata = borrow_global<PaymentMetadata<FakeCoin>>(customer_addr);
        assert!(!payment_metadata.active, EPAYMENT_METADATA_IS_STILL_ACTIVE);
        activate_subscription<FakeCoin>(&customer, merchant_addr, constants.cycles, customer_signer_capability_offer_bytes , customer_pk_bytes);
        let payment_metadata = borrow_global<PaymentMetadata<FakeCoin>>(customer_addr);
        assert!(payment_metadata.active, EPAYMENT_METADATA_IS_STILL_ACTIVE);
        // Collecting payments to check if the account was successfully delegated or not 
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + 3 * constants.amount_to_collect_per_period), EINVALID_BALANCE); 
        // Closing the subscription which would move the resource and destroy it.
        // If the user wants to subscribe again, they need to initialize the payment metadata
        close_subscription<FakeCoin>(&customer, merchant_addr);
    }   

    #[test(module_owner= @Subscription, merchant= @0x5, aptos_framework = @0x1 )]
    public entry fun able_to_recharge_more_cycles(module_owner: signer, merchant: signer, aptos_framework: signer) acquires PaymentConfig, PaymentMetadata {
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let constants = get_constants();
        let (customer_pk_bytes, customer, customer_signer_capability_offer_bytes, _delegated_resource) = create_account_and_sign_challenge(constants.subscription_name);

        let merchant_addr = signer::address_of(&merchant);
        let customer_addr = signer::address_of(&customer);
        
        initialize_coin_and_mint(&module_owner, &customer, constants.initial_mint_amount);
        assert!(coin::balance<FakeCoin>(customer_addr) == constants.initial_mint_amount, EINVALID_BALANCE);
        aptos_account::create_account(merchant_addr);
        managed_coin::register<FakeCoin>(&merchant);

        initialize_merchant_authority(&merchant);
        assert!(exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_NOT_CREATED);

        initialize_payment_config<FakeCoin>(&merchant, merchant_addr, constants.collect_on_init, constants.amount_to_collect_on_init, constants.amount_to_collect_per_period, constants.time_interval, constants.subscription_name);
        assert!(exists<PaymentConfig<FakeCoin>>(merchant_addr), EPAYMENT_CONFIG_NOT_CREATED);

        initialize_payment_metadata<FakeCoin>(&customer, merchant_addr, constants.cycles, customer_signer_capability_offer_bytes, customer_pk_bytes);
        assert!(exists<PaymentMetadata<FakeCoin>>(customer_addr), EPAYMENT_METADATA_NOT_CREATED);
        assert!(coin::balance<FakeCoin>(merchant_addr) == constants.amount_to_collect_on_init, EINVALID_BALANCE);
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + constants.amount_to_collect_per_period), EINVALID_BALANCE);
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + 2*constants.amount_to_collect_per_period), EINVALID_BALANCE);
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + 3*constants.amount_to_collect_per_period), EINVALID_BALANCE);
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + 4*constants.amount_to_collect_per_period), EINVALID_BALANCE);
        // Since only 4 cycles were approved, the subscriber has to recharge else the next cycle payment would fail
        recharge_subscription<FakeCoin>(&customer, merchant_addr, constants.cycles);
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + 5*constants.amount_to_collect_per_period), EINVALID_BALANCE);
    }

    #[test(module_owner= @Subscription, merchant= @0x5, aptos_framework = @0x1 )]
    #[expected_failure(abort_code = ESUBSCRIPTION_IS_INACTIVE)]
    public entry fun cannot_collect_payment_after_revoking(module_owner: signer, merchant: signer, aptos_framework: signer) acquires PaymentConfig, PaymentMetadata {
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let constants = get_constants();
        let (customer_pk_bytes, customer, customer_signer_capability_offer_bytes, _delegated_resource) = create_account_and_sign_challenge(constants.subscription_name);

        let merchant_addr = signer::address_of(&merchant);
        let customer_addr = signer::address_of(&customer);
        
        initialize_coin_and_mint(&module_owner, &customer, constants.initial_mint_amount);
        assert!(coin::balance<FakeCoin>(customer_addr) == constants.initial_mint_amount, EINVALID_BALANCE);
        aptos_account::create_account(merchant_addr);
        managed_coin::register<FakeCoin>(&merchant);

        initialize_merchant_authority(&merchant);
        assert!(exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_NOT_CREATED);

        initialize_payment_config<FakeCoin>(&merchant, merchant_addr, constants.collect_on_init, constants.amount_to_collect_on_init, constants.amount_to_collect_per_period, constants.time_interval, constants.subscription_name);
        assert!(exists<PaymentConfig<FakeCoin>>(merchant_addr), EPAYMENT_CONFIG_NOT_CREATED);

        initialize_payment_metadata<FakeCoin>(&customer, merchant_addr, constants.cycles, customer_signer_capability_offer_bytes, customer_pk_bytes);
        assert!(exists<PaymentMetadata<FakeCoin>>(customer_addr), EPAYMENT_METADATA_NOT_CREATED);
        assert!(coin::balance<FakeCoin>(merchant_addr) == constants.amount_to_collect_on_init, EINVALID_BALANCE);
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + constants.amount_to_collect_per_period), EINVALID_BALANCE);
        // Collecting for second cycle
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + 2 * constants.amount_to_collect_per_period), EINVALID_BALANCE);
        // Revoking and activating subscription by revoking and offering the delegation respectively.
        revoke_subscription<FakeCoin>(&customer, merchant_addr);
        let payment_metadata = borrow_global<PaymentMetadata<FakeCoin>>(customer_addr);
        assert!(!payment_metadata.active, EPAYMENT_METADATA_IS_STILL_ACTIVE);
        // Since the signer capability has been revoked, collecting payments now would result in abort
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr)
    }

    #[test(module_owner= @Subscription, merchant= @0x5, aptos_framework = @0x1 )]
    #[expected_failure(abort_code = ETIME_INTERVAL_NOT_ELAPSED)]
    public entry fun cannot_collect_payment_before_time_interval(module_owner: signer, merchant: signer, aptos_framework: signer) acquires PaymentConfig, PaymentMetadata {
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let constants = get_constants();
        let (customer_pk_bytes, customer, customer_signer_capability_offer_bytes, _delegated_resource) = create_account_and_sign_challenge(constants.subscription_name);

        let merchant_addr = signer::address_of(&merchant);
        let customer_addr = signer::address_of(&customer);
        
        initialize_coin_and_mint(&module_owner, &customer, constants.initial_mint_amount);
        assert!(coin::balance<FakeCoin>(customer_addr) == constants.initial_mint_amount, EINVALID_BALANCE);
        aptos_account::create_account(merchant_addr);
        managed_coin::register<FakeCoin>(&merchant);

        initialize_merchant_authority(&merchant);
        assert!(exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_NOT_CREATED);

        initialize_payment_config<FakeCoin>(&merchant, merchant_addr, constants.collect_on_init, constants.amount_to_collect_on_init, constants.amount_to_collect_per_period, constants.time_interval, constants.subscription_name);
        assert!(exists<PaymentConfig<FakeCoin>>(merchant_addr), EPAYMENT_CONFIG_NOT_CREATED);

        initialize_payment_metadata<FakeCoin>(&customer, merchant_addr, constants.cycles, customer_signer_capability_offer_bytes, customer_pk_bytes);
        assert!(exists<PaymentMetadata<FakeCoin>>(customer_addr), EPAYMENT_METADATA_NOT_CREATED);
        assert!(coin::balance<FakeCoin>(merchant_addr) == constants.amount_to_collect_on_init, EINVALID_BALANCE);
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + constants.amount_to_collect_per_period), EINVALID_BALANCE);
        // Collecting for second cycle but collecting before the time interval so this would fail
        collect_payment<FakeCoin>(&merchant, customer_addr);
    }

    #[test(module_owner= @Subscription, merchant= @0x5, aptos_framework = @0x1 )]
    #[expected_failure(abort_code = ELOW_DELEGATED_AMOUNT)]
    public entry fun cannot_collect_more_than_delegated_amount(module_owner: signer, merchant: signer, aptos_framework: signer) acquires PaymentConfig, PaymentMetadata {
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let constants = get_constants();
        let (customer_pk_bytes, customer, customer_signer_capability_offer_bytes, _delegated_resource) = create_account_and_sign_challenge(constants.subscription_name);

        let merchant_addr = signer::address_of(&merchant);
        let customer_addr = signer::address_of(&customer);
        
        initialize_coin_and_mint(&module_owner, &customer, constants.initial_mint_amount);
        assert!(coin::balance<FakeCoin>(customer_addr) == constants.initial_mint_amount, EINVALID_BALANCE);
        aptos_account::create_account(merchant_addr);
        managed_coin::register<FakeCoin>(&merchant);

        initialize_merchant_authority(&merchant);
        assert!(exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_NOT_CREATED);

        initialize_payment_config<FakeCoin>(&merchant, merchant_addr, constants.collect_on_init, constants.amount_to_collect_on_init, constants.amount_to_collect_per_period, constants.time_interval, constants.subscription_name);
        assert!(exists<PaymentConfig<FakeCoin>>(merchant_addr), EPAYMENT_CONFIG_NOT_CREATED);

        initialize_payment_metadata<FakeCoin>(&customer, merchant_addr, constants.cycles, customer_signer_capability_offer_bytes, customer_pk_bytes);
        assert!(exists<PaymentMetadata<FakeCoin>>(customer_addr), EPAYMENT_METADATA_NOT_CREATED);
        assert!(coin::balance<FakeCoin>(merchant_addr) == constants.amount_to_collect_on_init, EINVALID_BALANCE);
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + constants.amount_to_collect_per_period), EINVALID_BALANCE);
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + 2*constants.amount_to_collect_per_period), EINVALID_BALANCE);
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + 3*constants.amount_to_collect_per_period), EINVALID_BALANCE);
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
        assert!(coin::balance<FakeCoin>(merchant_addr) == (constants.amount_to_collect_on_init + 4*constants.amount_to_collect_per_period), EINVALID_BALANCE);
        // only 4 cycles were approved so the fifth payment would fail
        timestamp::fast_forward_seconds(constants.time_interval + 2);
        collect_payment<FakeCoin>(&merchant, customer_addr);
    }




}