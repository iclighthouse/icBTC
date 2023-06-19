import ICBTC "bitcoin/ICBTC";
import Script "bitcoin/lib/Script";

module {
  public type Account = { owner : Principal; subaccount : ?[Nat8] };
  public type Address = Text;
  public type TypeAddress = {
    #p2pkh : Text;
  };
  public type BitcoinAddress = {
    #p2sh : [Nat8];
    #p2wpkh_v0 : [Nat8];
    #p2pkh : [Nat8];
  };
  public type BtcNetwork = { #Mainnet; #Regtest; #Testnet };
  public type UpgradeArgs = {
    retrieve_btc_min_amount : ?Nat64;
    max_time_in_queue_nanos : ?Nat64;
    min_confirmations : ?Nat32;
    mode : ?Mode;
};
  public type Event = {
    #received_utxos : { to_account : Account; utxos : [Utxo] };
    #sent_transaction : {
      change_output : ?{ value : Nat64; vout : Nat32 };
      txid : [Nat8];
      utxos : [Utxo];
      requests : [Nat64]; // blockIndex
      submitted_at : Nat64; // txi
    };
    #init : InitArgs;
    #upgrade : UpgradeArgs;
    #accepted_retrieve_btc_request : {
      received_at : Nat64;
      block_index : Nat64;
      address : BitcoinAddress;
      amount : Nat64;
    };
    #removed_retrieve_btc_request : { block_index : Nat64 };
    #confirmed_transaction : { txid : [Nat8] };
  };
  public type Mode = {
    #ReadOnly;
    #RestrictedTo : [Principal];
    #GeneralAvailability;
  };
  public type InitArgs = {
    ecdsa_key_name : Text;
    retrieve_btc_min_amount : Nat64;
    ledger_id : Principal;
    max_time_in_queue_nanos : Nat64;
    btc_network : BtcNetwork;
    min_confirmations: ?Nat32;
    mode : Mode;
  };
  public type RetrieveBtcArgs = { address : Text; amount : Nat64 };
  public type RetrieveBtcError = {
    #MalformedAddress : Text;
    #GenericError : { error_message : Text; error_code : Nat64 };
    #TemporarilyUnavailable : Text;
    #AlreadyProcessing;
    #AmountTooLow : Nat64;
    #InsufficientFunds : { balance : Nat64 };
  };
  public type RetrieveBtcOk = { block_index : Nat64 };
  public type RetrieveBtcStatus = {
    #Signing;
    #Confirmed : { txid : [Nat8] };
    #Sending : { txid : [Nat8] };
    #AmountTooLow;
    #Unknown;
    #Submitted : { txid : [Nat8] };
    #Pending;
  };
  public type UpdateBalanceError = {
    #GenericError : { error_message : Text; error_code : Nat64 };
    #TemporarilyUnavailable : Text;
    #AlreadyProcessing;
    #NoNewUtxos; //*
  };
  public type UpdateBalanceResult = { block_index : Nat64; amount : Nat64 };
  public type ICUtxo = ICBTC.Utxo; // Minter.Utxo?
  public type Utxo = {
    height : Nat32;
    value : Nat64; // Satoshi
    outpoint : { txid : [Nat8]; vout : Nat32 }; // txid: Blob
  };
  public type PubKey = [Nat8];
  public type DerivationPath = [Blob];
  public type VaultUtxo = (Address, PubKey, DerivationPath, ICUtxo);
  public type RetrieveStatus = {
    account: Account;
    retrieveAccount: Account;
    burnedBlockIndex: Nat;
    btcAddress: Address;
    amount: Nat64; // Satoshi
    txIndex: Nat;
  };
  public type SendingBtcStatus = {
    destinations: [(Nat64, Address, Nat64)];
    totalAmount: Nat64;
    utxos: [VaultUtxo];
    scriptSigs: [Script.Script];
    fee: Nat64;
    toids: [Nat];
    signedTx: ?[Nat8];
    status: RetrieveBtcStatus;
  };
  public type Self = InitArgs -> async actor {
    get_btc_address : shared { subaccount : ?[Nat8] } -> async Text;
    get_events : shared query { start : Nat64; length : Nat64 } -> async [
        Event
      ];
    get_withdrawal_account : shared () -> async Account;
    retrieve_btc : shared RetrieveBtcArgs -> async {
        #Ok : RetrieveBtcOk;
        #Err : RetrieveBtcError;
      };
    retrieve_btc_status : shared query {
        block_index : Nat64;
      } -> async RetrieveBtcStatus;
    update_balance : shared { subaccount : ?[Nat8] } -> async {
        #Ok : UpdateBalanceResult;
        #Err : UpdateBalanceError;
      };
  }
}