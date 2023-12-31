/**
 * Module     : icBTC Minter
 * Author     : ICLighthouse Team
 *              the basic_bitcoin library modified according to https://github.com/dfinity/examples/tree/master/motoko/basic_bitcoin
 * License    : Apache License 2.0
 * Stability  : Experimental
 * Github     : https://github.com/iclighthouse/
 */

import Prim "mo:⛔";
import Trie "./lib/Elastic-Trie";
import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Option "mo:base/Option";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Int "mo:base/Int";
import Int32 "mo:base/Int32";
import Int64 "mo:base/Int64";
import Float "mo:base/Float";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Time "mo:base/Time";
import Text "mo:base/Text";
import Deque "mo:base/Deque";
import Order "mo:base/Order";
import Cycles "mo:base/ExperimentalCycles";
import ICRC1 "./lib/ICRC1";
import Binary "./lib/Binary";
import Tools "./lib/Tools";
import SagaTM "./ICTC/SagaTM";
import DRC207 "./lib/DRC207";
import Error "mo:base/Error";
import Debug "mo:base/Debug";
import Result "mo:base/Result";
import EcdsaTypes "lib/bitcoin/ecdsa/Types";
import P2pkh "lib/bitcoin/lib/P2pkh";
import Bitcoin "lib/bitcoin/lib/Bitcoin";
import Address "lib/bitcoin/lib/Address";
import Transaction "lib/bitcoin/lib/Transaction";
import Script "lib/bitcoin/lib/Script";
import Publickey "lib/bitcoin/ecdsa/Publickey";
import Der "lib/bitcoin/ecdsa/Der";
import Affine "lib/bitcoin/ec/Affine";
import TxInput "lib/bitcoin/lib/TxInput";
import TxOutput "lib/bitcoin/lib/TxOutput";
import ICBTC "lib/bitcoin/ICBTC";
import Utils "lib/bitcoin/Utils";
import Minter "lib/MinterTypes";
//import Wallet "lib/bitcoin/Wallet";

// InitArgs = {
//     ecdsa_key_name : Text; // key_1
//     retrieve_btc_min_amount : Nat64; // 10000
//     ledger_id : Principal; // 3fwop-7iaaa-aaaak-adzca-cai / 3qr7c-6aaaa-aaaak-adzbq-cai
//     max_time_in_queue_nanos : Nat64;
//     btc_network : BtcNetwork; // #Mainnet
//     min_confirmations : ?Nat32
//     mode: Mode;
//   };
// record{ecdsa_key_name="key_1";retrieve_btc_min_amount=20000;ledger_id=principal "3fwop-7iaaa-aaaak-adzca-cai"; max_time_in_queue_nanos=0; btc_network=variant{Mainnet}; min_confirmations=opt 6; mode=variant{GeneralAvailability}}
shared(installMsg) actor class icBTCMinter(initArgs: Minter.InitArgs) = this {
    assert(initArgs.ecdsa_key_name == "key_1"); /*config*/
    assert(initArgs.btc_network == #Mainnet); /*config*/
    assert(Option.get(initArgs.min_confirmations, 0:Nat32) > 3); /*config*/
    type Network = Minter.BtcNetwork;
    type Address = ICBTC.BitcoinAddress; // Minter.BitcoinAddress?
    type TypeAddress = Minter.TypeAddress;
    type Satoshi = ICBTC.Satoshi; // Nat64
    type Utxo = ICBTC.Utxo; // Minter.Utxo?
    type MillisatoshiPerByte = ICBTC.MillisatoshiPerByte;
    type PublicKey = EcdsaTypes.PublicKey;
    type Transaction = Transaction.Transaction;
    type Script = Script.Script;
    type SighashType = Nat32;
    type Cycles = Nat;
    type Timestamp = Nat; // seconds
    type Sa = [Nat8];
    type BlockHeight = Nat64;
    type AccountId = Blob;
    type PubKey = Minter.PubKey;
    type DerivationPath = Minter.DerivationPath;
    type VaultUtxo = Minter.VaultUtxo;
    type Txid = Blob;
    type Event = Minter.Event;
    type TrieList<K, V> = {data: [(K, V)]; total: Nat; totalPage: Nat; };
    type SignFun = (Text, [Blob], Blob) -> async Blob;

    let CURVE = ICBTC.CURVE;
    let SIGHASH_ALL : SighashType = 0x01;
    let NETWORK : Network = initArgs.btc_network;
    let KEY_NAME : Text = initArgs.ecdsa_key_name;
    let MIN_CONFIRMATIONS : Nat32 = Option.get(initArgs.min_confirmations, 6:Nat32);
    let BTC_MIN_AMOUNT: Nat64 = initArgs.retrieve_btc_min_amount;
    let GET_BALANCE_COST_CYCLES : Cycles = 100_000_000;
    let GET_UTXOS_COST_CYCLES : Cycles = 10_000_000_000;
    let GET_CURRENT_FEE_PERCENTILES_COST_CYCLES : Cycles = 100_000_000;
    let SEND_TRANSACTION_BASE_COST_CYCLES : Cycles = 5_000_000_000;
    let SEND_TRANSACTION_COST_CYCLES_PER_BYTE : Cycles = 20_000_000;
    let ECDSA_SIGN_CYCLES : Cycles = 22_000_000_000;
    let ICTC_RUN_INTERVAL : Nat = 10;
    let MIN_VISIT_INTERVAL : Nat = 30; //seconds
    let AVG_TX_BYTES : Nat64 = 450; /*config*/
    
    private var app_debug : Bool = false; /*config*/
    private let version_: Text = "0.1"; /*config*/
    private let ns_: Nat = 1000000000;
    private var pause: Bool = initArgs.mode == #ReadOnly;
    private stable var owner: Principal = installMsg.caller;
    private stable var ic_: Principal = Principal.fromText("aaaaa-aa"); 
    private stable var icBTC_: Principal = initArgs.ledger_id; //Principal.fromText("3fwop-7iaaa-aaaak-adzca-cai"); 
    if (app_debug){
        icBTC_ := Principal.fromText("3qr7c-6aaaa-aaaak-adzbq-cai");
    };
    private let ic : ICBTC.Self = actor(Principal.toText(ic_));
    private let icBTC : ICRC1.Self = actor(Principal.toText(icBTC_));
    private stable var icBTCFee: Nat = 20;
    private stable var btcFee: Nat64 = 3000;  // MillisatoshiPerByte
    private stable var lastUpdateFeeTime : Time.Time = 0;
    private stable var countRejections: Nat = 0;
    private stable var lastExecutionDuration: Int = 0;
    private stable var maxExecutionDuration: Int = 0;
    private stable var lastSagaRunningTime : Time.Time = 0;
    private stable var countAsyncMessage : Nat = 0;

    private stable var blockIndex : BlockHeight = 0;
    private stable var minterUtxos = Deque.empty<VaultUtxo>(); // (Address, PubKey, DerivationPath, Utxo);
    private stable var minterRemainingBalance : Nat64 = 0;
    private stable var totalBtcFee: Nat64 = 0;
    private stable var totalBtcReceiving: Nat64 = 0;
    private stable var totalBtcSent: Nat64 = 0;
    private stable var lastFetchUtxosTime : Time.Time = 0;
    private stable var accountUtxos = Trie.empty<Address, (PubKey, DerivationPath, [Utxo])>(); 
    private stable var latestVisitTime = Trie.empty<Principal, Timestamp>(); 
    private stable var retrieveBTC = Trie.empty<Nat, Minter.RetrieveStatus>();  
    private stable var sendingBTC = Trie.empty<Nat, Minter.SendingBtcStatus>();  
    private stable var txIndex : Nat = 0;
    private stable var lastTxTime : Time.Time = 0;
    private stable var blockEvents = Trie.empty<Nat, Event>(); 
    private stable var minter_public_key : [Nat8] = [];
    private stable var minter_address = "";

    private func _getEvent(_blockIndex: Nat64) : ?Event{
        switch(Trie.get(blockEvents, keyn(Nat64.toNat(_blockIndex)), Nat.equal)){
            case(?(event)){ return ?event };
            case(_){ return null };
        };
    };
    private func _getEvents(_start : Nat64, _length : Nat64) : [Event]{
        assert(_length > 0);
        var events : [Event] = [];
        for (index in Iter.range(Nat64.toNat(_start), Nat64.toNat(_start) + Nat64.toNat(_length) - 1)){
            switch(Trie.get(blockEvents, keyn(index), Nat.equal)){
                case(?(event)){ events := Tools.arrayAppend([event], events)};
                case(_){};
            };
        };
        return events;
    };
    private func _addMinterUtxos(_address: Address, _pubkey: PubKey, _dpath: DerivationPath, _utxos: [Utxo]) : (){
        for (utxo in Array.reverse(_utxos).vals()){
            let vaultUtxo : VaultUtxo = (_address, _pubkey, _dpath, utxo);
            minterUtxos := Deque.pushFront(minterUtxos, vaultUtxo);
            minterRemainingBalance += utxo.value;
        };
    };
    private func _getAccountUtxos(_address: Address) : ?(PubKey, DerivationPath, [Utxo]){
        switch(Trie.get(accountUtxos, keyt(_address), Text.equal)){
            case(?(item)){ return ?item };
            case(_){ return null };
        };
    };
    private func _addAccountUtxos(_address: Address, _pubkey: PubKey, _dpath: DerivationPath, _utxos: [Utxo]) : (){
        switch(Trie.get(accountUtxos, keyt(_address), Text.equal)){
            case(?(item)){
                var utxos = _utxos;
                if (item.2.size() < 500){
                    utxos := Tools.arrayAppend(utxos, item.2);
                };
                accountUtxos := Trie.put(accountUtxos, keyt(_address), Text.equal, (_pubkey, _dpath, utxos)).0;
            };
            case(_){
                accountUtxos := Trie.put(accountUtxos, keyt(_address), Text.equal, (_pubkey, _dpath, _utxos)).0;
            };
        };
    };
    private func _getLatestVisitTime(_address: Principal) : Timestamp{
        switch(Trie.get(latestVisitTime, keyp(_address), Principal.equal)){
            case(?(v)){ return v };
            case(_){ return 0 };
        };
    };
    private func _setLatestVisitTime(_address: Principal) : (){
        latestVisitTime := Trie.put(latestVisitTime, keyp(_address), Principal.equal, _now()).0;
        latestVisitTime := Trie.filter(latestVisitTime, func (k: Principal, v: Timestamp): Bool{ 
            _now() < v + 24*3600
        });
    };

    private func _now() : Timestamp{
        return Int.abs(Time.now() / ns_);
    };
    private func _asyncMessageSize() : Nat{
        return countAsyncMessage + _getSaga().asyncMessageSize();
    };
    private func _checkAsyncMessageLimit() : Bool{
        return _asyncMessageSize() < 400; /*config*/
    };
    private func keyb(t: Blob) : Trie.Key<Blob> { return { key = t; hash = Blob.hash(t) }; };
    private func keyt(t: Text) : Trie.Key<Text> { return { key = t; hash = Text.hash(t) }; };
    private func keyp(t: Principal) : Trie.Key<Principal> { return { key = t; hash = Principal.hash(t) }; };
    private func keyn(t: Nat) : Trie.Key<Nat> { return { key = t; hash = Tools.natHash(t) }; };
    private func trieItems<K, V>(_trie: Trie.Trie<K,V>, _page: Nat, _size: Nat) : TrieList<K, V> {
        let length = Trie.size(_trie);
        if (_page < 1 or _size < 1){
            return {data = []; totalPage = 0; total = length; };
        };
        let offset = Nat.sub(_page, 1) * _size;
        var totalPage: Nat = length / _size;
        if (totalPage * _size < length) { totalPage += 1; };
        if (offset >= length){
            return {data = []; totalPage = totalPage; total = length; };
        };
        let end: Nat = offset + Nat.sub(_size, 1);
        var i: Nat = 0;
        var res: [(K, V)] = [];
        for ((k,v) in Trie.iter<K, V>(_trie)){
            if (i >= offset and i <= end){
                res := Tools.arrayAppend(res, [(k,v)]);
            };
            i += 1;
        };
        return {data = res; totalPage = totalPage; total = length; };
    };
    private func _toSaBlob(_sa: ?Sa) : ?Blob{
        switch(_sa){
            case(?(sa)){ return ?Blob.fromArray(sa); };
            case(_){ return null; };
        }
    };
    private func _toSaNat8(_sa: ?Blob) : ?[Nat8]{
        switch(_sa){
            case(?(sa)){ return ?Blob.toArray(sa); };
            case(_){ return null; };
        }
    };
    private func _toOptSub(_sub: Blob) : ?Blob{
        if (Blob.toArray(_sub).size() == 0){
            return null;
        }else{
            return ?_sub;
        };
    };
    private func _vaultToUtxos(_utxos: [VaultUtxo]): [Minter.Utxo]{
        var utxos : [Minter.Utxo] = [];
        for ((address, pubKey, derivationPath, utxo) in _utxos.vals()){
            utxos := Tools.arrayAppend(utxos, _toUtxosArr([utxo]));
        };
        return utxos;
    };
    private func _toUtxosArr(_utxos: [ICBTC.Utxo]): [Minter.Utxo]{
        var utxos : [Minter.Utxo] = [];
        for (utxo in _utxos.vals()){
            utxos := Tools.arrayAppend(utxos, [{
                height  = utxo.height;
                value  = utxo.value; // Satoshi
                outpoint = { txid = Blob.toArray(utxo.outpoint.txid); vout = utxo.outpoint.vout }; 
            }]);
        };
        return utxos;
    };
    private func _natToFloat(_n: Nat) : Float{
        return Float.fromInt64(Int64.fromNat64(Nat64.fromNat(_n)));
    };
    private func _fromHeight(_h: BlockHeight) : Txid{
        return Blob.fromArray(Binary.BigEndian.fromNat64(_h));
    };
    private func _toHeight(_txid: Txid) : BlockHeight{
        return Binary.BigEndian.toNat64(Blob.toArray(_txid));
    };
    private func _onlyOwner(_caller: Principal) : Bool { //ict
        return _caller == owner;
    }; 
    private func _notPaused() : Bool { 
        return not(pause);
    };

    /// SagaTM
    // Local tasks
    private func _local_buildTx(_txi: Nat) : async {txi: Nat; signedTx: [Nat8]}{ 
        switch(Trie.get(sendingBTC, keyn(_txi), Nat.equal)){
            case(?(tx)){
                if (tx.status == #Signing){
                    let signed = await _buildSignedTx(_txi, tx.utxos, tx.destinations, tx.fee);
                    ignore _updateSendingBtc(_txi, null, null, ?signed.tx, ?#Sending({ txid = signed.txid }), [], ?[]);
                    if (tx.toids.size() > 0){
                        let toid = tx.toids[tx.toids.size()-1];
                        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi)));
                        let saga = _getSaga();
                        saga.open(toid);
                        let task = _buildTask(?txiBlob, Principal.fromActor(this), #This(#sendTx(_txi, signed.txid)), [], 0);
                        let ttid = saga.push(toid, task, null, null);
                        saga.close(toid);
                    }else{
                        throw Error.reject("415: The toid does not exist!");
                    };
                    return {txi = _txi; signedTx = signed.tx };
                }else{
                    throw Error.reject("415: Transaction status is not equal to #Signing!");
                };
            };
            case(_){ throw Error.reject("415: The transaction record does not exist!"); };
        };
    };
    private func _local_sendTx(_txi: Nat, _txid: [Nat8]) : async {txi: Nat; destinations: [(Nat64, Text, Nat64)]; txid: Text}{ 
        switch(Trie.get(sendingBTC, keyn(_txi), Nat.equal)){
            case(?(tx)){
                if (Option.isSome(tx.signedTx)){
                    let signedTx: [Nat8] = Option.get(tx.signedTx, []);
                    let transaction_fee = SEND_TRANSACTION_BASE_COST_CYCLES + signedTx.size() * SEND_TRANSACTION_COST_CYCLES_PER_BYTE;
                    Cycles.add(transaction_fee);
                    await ic.bitcoin_send_transaction({ network = NETWORK; transaction = signedTx; });
                    ignore _updateSendingBtc(_txi, null, null, null, ?#Submitted({ txid = _txid }), [], ?[]);
                    var i : Nat32 = 0;
                    let eventUtxos = _vaultToUtxos(tx.utxos);
                    for (dest in tx.destinations.vals()){
                        let event : Minter.Event = #sent_transaction({ change_output = ?{value = dest.2; vout = i }; txid = _txid; utxos = eventUtxos; requests = [dest.0]; submitted_at = Nat64.fromNat(_now()) });
                        blockEvents := Trie.put(blockEvents, keyn(Nat64.toNat(blockIndex)), Nat.equal, event).0;
                        i += 1;
                        blockIndex += 1;
                    };
                    return {txi = _txi; destinations = tx.destinations; txid = Utils.bytesToText(_txid) };
                }else{
                    throw Error.reject("416: The signedTx field cannot be empty!");
                };
            };
            case(_){ throw Error.reject("416: The transaction record does not exist!"); };
        };
    };
    // Local task entrance
    // private func _local(_args: SagaTM.CallType, _receipt: ?SagaTM.Receipt) : (SagaTM.TaskResult){
    //     switch(_args){
    //         case(#This(method)){
    //             switch(method){
    //                 // case(#dip20Send(_a, _value)){
    //                 //     var result = (); // Receipt
    //                 //     // do
    //                 //     result := _dip20Send(_a, _value);
    //                 //     // check & return
    //                 //     return (#Done, ?#This(#dip20Send), null);
    //                 // };
    //                 case(_){return (#Error, null, ?{code=#future(9901); message="Non-local function."; });};
    //             };
    //         };
    //         case(_){ return (#Error, null, ?{code=#future(9901); message="Non-local function."; });};
    //     };
    // };
    private func _local(_args: SagaTM.CallType, _receipt: ?SagaTM.Receipt) : async (SagaTM.TaskResult){
        switch(_args){
            case(#This(method)){
                switch(method){
                    case(#buildTx(_txi)){
                        let result = await _local_buildTx(_txi);
                        return (#Done, ?#This(#buildTx(result)), null);
                    };
                    case(#sendTx(_txi, _txid)){
                        let result = await _local_sendTx(_txi, _txid);
                        return (#Done, ?#This(#sendTx(result)), null);
                    };
                    //case(_){return (#Error, null, ?{code=#future(9901); message="Non-local function."; });};
                };
            };
            case(_){ return (#Error, null, ?{code=#future(9901); message="Non-local function."; });};
        };
    };
    // Task callback
    // private func _taskCallback(_ttid: SagaTM.Ttid, _task: SagaTM.Task, _result: SagaTM.TaskResult) : (){
    //     //taskLogs := Tools.arrayAppend(taskLogs, [(_ttid, _task, _result)]);
    // };
    // // Order callback
    // private func _orderCallback(_toid: SagaTM.Toid, _status: SagaTM.OrderStatus, _data: ?Blob) : (){
    //     //orderLogs := Tools.arrayAppend(orderLogs, [(_toid, _status)]);
    // };
    // Create saga object
    private var saga: ?SagaTM.SagaTM = null;
    private func _getSaga() : SagaTM.SagaTM {
        switch(saga){
            case(?(_saga)){ return _saga };
            case(_){
                let _saga = SagaTM.SagaTM(Principal.fromActor(this), ?_local, null, null); //?_taskCallback, ?_orderCallback
                saga := ?_saga;
                return _saga;
            };
        };
    };
    private func _buildTask(_data: ?Blob, _callee: Principal, _callType: SagaTM.CallType, _preTtid: [SagaTM.Ttid], _cycles: Nat) : SagaTM.PushTaskRequest{
        return {
            callee = _callee;
            callType = _callType;
            preTtid = _preTtid;
            attemptsMax = ?3;
            recallInterval = ?200000000; // nanoseconds
            cycles = _cycles;
            data = _data;
        };
    };
    // Converts a public key to a P2PKH address.
    private func _public_key_to_p2pkh_address(public_key_bytes : [Nat8]) : Address {
        let public_key = _public_key_bytes_to_public_key(public_key_bytes);
        // Compute the P2PKH address from our public key.
        P2pkh.deriveAddress(#Mainnet, Publickey.toSec1(public_key, true))
    };
    private func _public_key_bytes_to_public_key(public_key_bytes : [Nat8]) : PublicKey {
        let point = Utils.unwrap(Affine.fromBytes(public_key_bytes, CURVE));
        Utils.get_ok(Publickey.decode(#point point))
    };
    private func _accountId(_owner: Principal, _subaccount: ?[Nat8]) : Blob{
        return Blob.fromArray(Tools.principalToAccount(_owner, _subaccount));
    };

    private func _getBtcFee() : async Nat64 {
        var fees : [Nat64] = [];
        try{
            countAsyncMessage += 2;
            Cycles.add(GET_CURRENT_FEE_PERCENTILES_COST_CYCLES);
            fees := await ICBTC.get_current_fee_percentiles(NETWORK);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage); 
        };
        if (fees.size() > 39) {
            return fees[39];
        }else{
            return 5000;
        };
    };

    /// update btc balances
    private func _fetchAccountAddress(_dpath: DerivationPath) : async (pubKey: [Nat8], address: Text){
        var own_public_key : [Nat8] = [];
        var own_address = "";
        let ecdsa_public_key = await ic.ecdsa_public_key({
            canister_id = null;
            derivation_path = _dpath;
            key_id = { curve = #secp256k1; name = KEY_NAME }; //dfx_test_key
        });
        own_public_key := Blob.toArray(ecdsa_public_key.public_key);
        own_address := _public_key_to_p2pkh_address(own_public_key);
        return (own_public_key, own_address);
    };
    private func _fetchAccountUtxos(_account : ?{owner: Principal; subaccount : ?[Nat8] }): async (address: Text, amount: Nat64, utxos: [Utxo]){
        var own_public_key : [Nat8] = [];
        var own_address = "";
        var dpath : [Blob] = [];
        switch(_account){
            case(?(account)){
                let accountId = _accountId(account.owner, account.subaccount);
                dpath := [accountId];
                try{
                    countAsyncMessage += 2;
                    let res = await _fetchAccountAddress(dpath);
                    own_public_key := res.0;
                    own_address := res.1;
                    countAsyncMessage -= Nat.min(2, countAsyncMessage);
                }catch(e){
                    countAsyncMessage -= Nat.min(2, countAsyncMessage);
                    throw Error.reject("410: Error in fetching public key!");
                };
            };
            case(_){
                own_public_key := minter_public_key;
                own_address := minter_address;
                dpath := [];
            };
        };
        // {
        //     utxos : [Utxo];
        //     tip_block_hash : BlockHash;
        //     tip_height : Nat32;
        //     next_page : ?Page; // 1000 utxos per Page
        // }
        var amount : Nat64 = 0;
        var utxos : [Utxo] = [];
        try {
            countAsyncMessage += 2;
            Cycles.add(GET_UTXOS_COST_CYCLES);
            var utxosResponse = await ic.bitcoin_get_utxos({
                address = own_address;
                network = NETWORK;
                filter = ?#MinConfirmations(MIN_CONFIRMATIONS); 
            });
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            var isNewUtxos : Bool = false;
            var utxosRecorded : [Utxo] = [];
            switch(_getAccountUtxos(own_address)){
                case(?(item)){ utxosRecorded := item.2 };
                case(_){};
            };
            for (utxo in utxosResponse.utxos.vals()){
                if (utxosRecorded.size() == 0 or utxo.height > utxosRecorded[0].height){
                    utxos := Tools.arrayAppend(utxos, [utxo]);
                    amount += utxo.value;
                    isNewUtxos := true;
                };
            };
            _addMinterUtxos(own_address, own_public_key, dpath, utxos);
            _addAccountUtxos(own_address, own_public_key, dpath, utxos);
            label getNextPage while (Option.isSome(utxosResponse.next_page) and isNewUtxos){
                Cycles.add(GET_UTXOS_COST_CYCLES);
                utxosResponse := await ic.bitcoin_get_utxos({
                    address = own_address;
                    network = NETWORK;
                    filter = ?#Page(Option.get(utxosResponse.next_page, [])); 
                });
                switch(_getAccountUtxos(own_address)){
                    case(?(item)){ utxosRecorded := item.2 };
                    case(_){};
                };
                for (utxo in utxosResponse.utxos.vals()){
                    if (utxosRecorded.size() == 0 or utxo.height > utxosRecorded[0].height){
                        _addMinterUtxos(own_address, own_public_key, dpath, [utxo]);
                        _addAccountUtxos(own_address, own_public_key, dpath, [utxo]);
                        utxos := Tools.arrayAppend(utxos, [utxo]);
                        amount += utxo.value;
                    }else{
                        break getNextPage;
                    };
                };
            };
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("411: Error in bitcoin_get_utxos()!");
        };
        return (own_address, amount, utxos);
    };

    private func _pushSendingBtc(_txIndex: Nat, _blockIndex: BlockHeight, _dstAddress: Address, _amount: Nat64) : (){
        switch(Trie.get(sendingBTC, keyn(_txIndex), Nat.equal)){
            case(?(tx)){
                sendingBTC := Trie.put(sendingBTC, keyn(_txIndex), Nat.equal, {
                    destinations = Tools.arrayAppend(tx.destinations, [(_blockIndex, _dstAddress, _amount)]);
                    totalAmount = tx.totalAmount + _amount;
                    utxos = tx.utxos;
                    scriptSigs = tx.scriptSigs;
                    fee = tx.fee;
                    toids = tx.toids;
                    signedTx = tx.signedTx;
                    status = tx.status;
                }: Minter.SendingBtcStatus).0;
            };
            case(_){
                sendingBTC := Trie.put(sendingBTC, keyn(_txIndex), Nat.equal, {
                    destinations = [(_blockIndex, _dstAddress, _amount)];
                    totalAmount = _amount;
                    utxos = [];
                    scriptSigs = [];
                    fee = 0;
                    toids = [];
                    signedTx = null;
                    status = #Pending;
                } : Minter.SendingBtcStatus).0;
            };
        };
    };
    private func _updateSendingBtc(_txIndex: Nat, _utxos: ?[VaultUtxo], _fee: ?Nat64, _signedTx: ?[Nat8], _status: ?Minter.RetrieveBtcStatus,
    _addToid: [Nat], _addScript: ?[Script]) : Bool{
        switch(Trie.get(sendingBTC, keyn(_txIndex), Nat.equal)){
            case(?(tx)){
                var signedTx = tx.signedTx;
                if (Option.isSome(_signedTx)){
                    signedTx := _signedTx;
                };
                var scriptSigs = tx.scriptSigs;
                switch(_addScript){
                    case(?(addScript)){
                        scriptSigs := Tools.arrayAppend(scriptSigs, addScript);
                    };
                    case(_){
                        scriptSigs := []; // Clear
                    };
                };
                sendingBTC := Trie.put(sendingBTC, keyn(_txIndex), Nat.equal, {
                    destinations = tx.destinations;
                    totalAmount = tx.totalAmount;
                    utxos = Option.get(_utxos, tx.utxos);
                    scriptSigs = scriptSigs;
                    fee = Option.get(_fee, tx.fee);
                    toids = Tools.arrayAppend(tx.toids, _addToid);
                    signedTx = signedTx;
                    status = Option.get(_status, tx.status);
                }: Minter.SendingBtcStatus).0;
                return true;
            };
            case(_){ return false };
        };
    };
    private func _sendBtc(_txIndex: ?Nat) : async (){
        let txi = Option.get(_txIndex, txIndex);
        switch(Trie.get(sendingBTC, keyn(txi), Nat.equal)){
            case(?(tx)){
                if (tx.status == #Pending){
                    var dsts : [(TypeAddress, Satoshi)] = [];
                    for ((blockIndex, address, amount) in tx.destinations.vals()){
                        dsts := Tools.arrayAppend(dsts, [(#p2pkh(address), amount)]);
                    };
                    let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi)));
                    let saga = _getSaga();
                    let toid : Nat = saga.create("retrieve", #Forward, ?txiBlob, null);
                    // build tx test
                    let (txTest, totalFee) = _buildTxTest(dsts);
                    // build
                    let (transaction, spendUtxos, totalInput, totalSpend, remainingUtxos) = 
                    Utils.get_ok_except(_buildTransaction(2, minterUtxos, dsts, Nat64.fromNat(totalFee)), "Error building transaction.");
                    ignore _updateSendingBtc(txi, ?spendUtxos, ?Nat64.fromNat(totalFee), null, ?#Signing, [toid], ?[]);
                    minterUtxos := remainingUtxos;
                    minterRemainingBalance -= totalInput;
                    // ictc: signs / build - send
                    let task = _buildTask(?txiBlob, Principal.fromActor(this), #This(#buildTx(txi)), [], 0);
                    let ttid = saga.push(toid, task, null, null);
                    saga.close(toid);
                    // let sagaRes = await saga.run(toid);
                    if (toid > 0 and _asyncMessageSize() < 360){ 
                        lastSagaRunningTime := Time.now();
                        try{
                            countAsyncMessage += 2;
                            let sagaRes = await saga.run(toid);
                            countAsyncMessage -= Nat.min(2, countAsyncMessage);
                        }catch(e){
                            countAsyncMessage -= Nat.min(2, countAsyncMessage); 
                        };
                    }; 
                };
            };
            case(_){};
        };
    };
    private func _reSendBtc(_txIndex: Nat, _fee: Nat) : async (){
        let txi = _txIndex;
        switch(Trie.get(sendingBTC, keyn(txi), Nat.equal)){
            case(?(tx)){
                switch(tx.status){
                    case(#Submitted(preTxid)){
                        var dsts : [(TypeAddress, Satoshi)] = [];
                        for ((blockIndex, address, amount) in tx.destinations.vals()){
                            dsts := Tools.arrayAppend(dsts, [(#p2pkh(address), amount)]);
                        };
                        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi)));
                        let saga = _getSaga();
                        let toid : Nat = saga.create("retrieve", #Forward, ?txiBlob, null);
                        // reset fee
                        let totalFee = _fee; 
                        // build
                        // let (transaction, spendUtxos, totalInput, totalSpend, remainingUtxos) = 
                        // Utils.get_ok_except(_buildTransaction(2, _utxos, dsts, Nat64.fromNat(totalFee)), "Error building transaction.");
                        ignore _updateSendingBtc(txi, null, ?Nat64.fromNat(totalFee), null, ?#Signing, [toid], null);
                        // ictc: signs / build - send
                        let task = _buildTask(?txiBlob, Principal.fromActor(this), #This(#buildTx(txi)), [], 0);
                        let ttid = saga.push(toid, task, null, null);
                        saga.close(toid);
                        // let sagaRes = await saga.run(toid);
                        if (toid > 0 and _asyncMessageSize() < 360){ 
                            lastSagaRunningTime := Time.now();
                            try{
                                countAsyncMessage += 2;
                                let sagaRes = await saga.run(toid);
                                countAsyncMessage -= Nat.min(2, countAsyncMessage);
                            }catch(e){
                                countAsyncMessage -= Nat.min(2, countAsyncMessage); 
                            };
                        }; 
                    };
                    case(_){};
                };
            };
            case(_){};
        };
    };
    private func _signTxTest(transaction: Transaction, vUtxos: [VaultUtxo]) : [Nat8] { // key_name, signer
        assert(transaction.txInputs.size() == vUtxos.size());
        //let scriptSigs = Array.init<Script>(transaction.txInputs.size(), []);
        for (i in Iter.range(0, transaction.txInputs.size() - 1)) {
            switch (Address.scriptPubKey(#p2pkh(vUtxos[i].0))) {
                case (#ok(scriptPubKey)) {
                    // Obtain scriptSigs for each Tx input.
                    let sighash = transaction.createSignatureHash(scriptPubKey, Nat32.fromIntWrap(i), SIGHASH_ALL);
                    let signature_sec = Blob.fromArray(Array.freeze(Array.init<Nat8>(64, 255))); // Test
                    let signature_der = Blob.toArray(Der.encodeSignature(signature_sec));
                    // Append the sighash type.
                    let encodedSignatureWithSighashType = Array.tabulate<Nat8>(
                        signature_der.size() + 1, func (n) {
                        if (n < signature_der.size()) {
                            signature_der[n]
                        } else {
                            Nat8.fromNat(Nat32.toNat(SIGHASH_ALL))
                        };
                    });
                    // Create Script Sig which looks like:
                    // ScriptSig = <Signature> <Public Key>.
                    let script = [
                        #data(encodedSignatureWithSighashType),
                        #data(vUtxos[i].1)
                    ];
                    transaction.txInputs[i].script := script;
                };
                // Verify that our own address is P2PKH.
                case (#err(msg)){
                    Debug.trap("It supports signing p2pkh addresses only.");
                };
            };
        };
        transaction.toBytes()
    };
    private func _buildTxTest(
        destinations: [(TypeAddress, Satoshi)]
        ) : (tx: [Nat8], totalFee: Nat){ 
        let fee_per_byte_nat = Nat64.toNat(btcFee);
        var total_fee : Nat = 0;
        loop {
            let (transaction, spendUtxos, totalInput, totalSpend, remainingUtxos) = 
            Utils.get_ok_except(_buildTransaction(2, minterUtxos, destinations, Nat64.fromNat(total_fee)), "Error building transaction.");
            // Sign the transaction. In this case, we only care about the size of the signed transaction, so we use a mock signer here for efficiency.
            let signed_transaction_bytes = _signTxTest(transaction, spendUtxos);
            let signed_tx_bytes_len : Nat = signed_transaction_bytes.size();
            if((signed_tx_bytes_len * fee_per_byte_nat) / 1000 == total_fee) {
                Debug.print("Transaction built with fee " # debug_show(total_fee));
                return (transaction.toBytes(), total_fee);
            } else {
                total_fee := (signed_tx_bytes_len * fee_per_byte_nat) / 1000;
            }
        };
    };
    /// build tx
    private func _buildSignedTx(
        txi: Nat, 
        own_utxos: [VaultUtxo], // -> Deque.Deque<VaultUtxo>
        destinations: [(Nat64, Address, Satoshi)], // -> [(TypeAddress, Satoshi)]
        fee: Nat64
        ) : async {tx: [Nat8]; txid: [Nat8]} { 
        var _utxos : Deque.Deque<VaultUtxo> = Deque.empty();
        var _destinations : [(TypeAddress, Satoshi)] = [];
        for (utxo in own_utxos.vals()){
            var dpath = utxo.2;
            if (utxo.0 == minter_address){ // fix bug
                dpath := [];
            };
            _utxos := Deque.pushFront(_utxos, (utxo.0, utxo.1, dpath, utxo.3));
        };
        _destinations := Array.map<(Nat64, Address, Satoshi), (TypeAddress, Satoshi)>(destinations, func (t: (Nat64, Address, Satoshi)): (TypeAddress, Satoshi){
            (#p2pkh(t.1), t.2)
        });
        let (transaction, spendUtxos, totalInput, totalSpend, remainingUtxos) = 
        Utils.get_ok_except(_buildTransaction(2, _utxos, _destinations, fee), "414: Error building transaction.");
        let signed_transaction_bytes = await _signTx(txi, transaction, spendUtxos);
        return {tx = signed_transaction_bytes; txid = transaction.id() };
    };
    /// sign transaction
    private func _signTx(txi: Nat, transaction: Transaction, vUtxos: [VaultUtxo]) : async [Nat8] { // key_name
        assert(transaction.txInputs.size() == vUtxos.size());
        let scriptSigs = Array.init<Script>(transaction.txInputs.size(), []);

        for (i in Iter.range(0, transaction.txInputs.size() - 1)) {
            switch (Address.scriptPubKey(#p2pkh(vUtxos[i].0))) {
                case (#ok(scriptPubKey)) {
                    // Obtain scriptSigs for each Tx input.
                    let sighash = transaction.createSignatureHash(scriptPubKey, Nat32.fromIntWrap(i), SIGHASH_ALL);
                    //let signature_sec = await signer(KEY_NAME, vUtxos[i].2, Blob.fromArray(sighash));
                    Cycles.add(ECDSA_SIGN_CYCLES);
                    let res = await ic.sign_with_ecdsa({
                        message_hash = Blob.fromArray(sighash);
                        derivation_path = vUtxos[i].2;
                        key_id = {
                            curve = #secp256k1;
                            name = KEY_NAME;
                        };
                    });
                    let signature_sec = res.signature;
                    let signature_der = Blob.toArray(Der.encodeSignature(signature_sec));
                    // Append the sighash type.
                    let encodedSignatureWithSighashType = Array.tabulate<Nat8>(
                        signature_der.size() + 1, func (n) {
                        if (n < signature_der.size()) {
                            signature_der[n]
                        } else {
                            Nat8.fromNat(Nat32.toNat(SIGHASH_ALL))
                        };
                    });
                    // Create Script Sig which looks like:
                    // ScriptSig = <Signature> <Public Key>.
                    let script = [
                        #data(encodedSignatureWithSighashType),
                        #data(vUtxos[i].1)
                    ];
                    scriptSigs[i] := script;
                    ignore _updateSendingBtc(txi, null, null, null, null, [], ?[script]);
                };
                // Verify that our own address is P2PKH.
                case (#err(msg)){
                    throw Error.reject("413: It supports signing p2pkh addresses only."); 
                };
            };
        };
        // Assign ScriptSigs to their associated TxInputs.
        for (i in Iter.range(0, scriptSigs.size() - 1)) {
            transaction.txInputs[i].script := scriptSigs[i];
        };
        return transaction.toBytes();
    };
    /// build transaction
    private func _buildTransaction( version : Nat32, 
        own_utxos: Deque.Deque<VaultUtxo>,
        destinations : [(TypeAddress, Satoshi)], 
        fees : Satoshi
    ) : Result.Result<(Transaction.Transaction, [VaultUtxo], Nat64, Nat64, Deque.Deque<VaultUtxo>), Text> {
        let dustThreshold : Satoshi = 500;
        let defaultSequence : Nat32 = 0xffffffff;
        if (version != 1 and version != 2) {
            return #err ("Unexpected version number: " # Nat32.toText(version))
        };
        // Collect TxOutputs, making space for a potential extra output for change.
        let txOutputs = Buffer.Buffer<TxOutput.TxOutput>(destinations.size() + 1);
        var totalSpend : Satoshi = fees;
        for ((destAddr, destAmount) in destinations.vals()) {
            switch (Address.scriptPubKey(destAddr)) {
                case (#ok(destScriptPubKey)) {
                    txOutputs.add(TxOutput.TxOutput(destAmount, destScriptPubKey));
                    totalSpend += destAmount;
                };
                case (#err(msg)) {
                    return #err(msg);
                };
            };
        };
        // Select which UTXOs to spend. 
        var availableFunds : Satoshi = 0;
        let vUtxos: Buffer.Buffer<VaultUtxo> = Buffer.Buffer(2);
        let txInputs : Buffer.Buffer<TxInput.TxInput> = Buffer.Buffer(2); // * 
        var utxos = own_utxos;
        let size = List.size(utxos.0) + List.size(utxos.1);
        var x : Nat = 0;
        label UtxoLoop while (availableFunds < totalSpend){
            switch(Deque.popBack(utxos)){
                case(?(utxosNew, (address, pubKey, dpath, utxo))){
                    x += 1;
                    if (utxo.value >= totalSpend or (utxo.value > totalSpend/2 and x > Nat.min(size, 50)) or x > Nat.min(size*2, 100)){
                        utxos := utxosNew;
                        availableFunds += utxo.value;
                        vUtxos.add((address, pubKey, dpath, utxo));
                        txInputs.add(TxInput.TxInput(utxo.outpoint, defaultSequence)); // -- 
                    }else{
                        utxos := Deque.pushFront(utxosNew, (address, pubKey, dpath, utxo));
                    };
                    if (availableFunds >= totalSpend) {
                        // We have enough inputs to cover the amount we want to spend.
                        break UtxoLoop;
                    };
                };
                case(_){ return #err("Insufficient balance"); };
            };
        };
        // sort
        // vUtxos.sort(func (x:VaultUtxo, y:VaultUtxo): Order.Order{
        //     Nat64.compare(x.3.value, y.3.value)
        // });
        // filter
        // var i: Nat = 0;
        // let vUtxos2 = Buffer.clone(vUtxos);
        // for ((address, pubKey, dpath, utxo) in vUtxos.vals()){
        //     if (availableFunds - utxo.value >= totalSpend){
        //         utxos := Deque.pushFront(utxos, (address, pubKey, dpath, utxo));
        //         availableFunds -= utxo.value;
        //         let v = vUtxos2.remove(i);
        //     }else{
        //         txInputs.add(TxInput.TxInput(utxo.outpoint, defaultSequence));
        //         i += 1;
        //     };
        // };
        // If there is remaining amount that is worth considering then include a change TxOutput.
        let remainingAmount : Satoshi = availableFunds - totalSpend;
        if (remainingAmount > dustThreshold) {
            switch (Address.scriptPubKey(#p2pkh(minter_address))) {
                case (#ok(chScriptPubKey)) {
                txOutputs.add(TxOutput.TxOutput(remainingAmount, chScriptPubKey));
                };
                case (#err(msg)) {
                return #err(msg);
                };
            };
        };
        // return
        let tx = Transaction.Transaction(version, Buffer.toArray(txInputs), Buffer.toArray(txOutputs), 0);
        return #ok(tx, Buffer.toArray(vUtxos), availableFunds, totalSpend, utxos);
    };

    private func _hasSendingBTC(_txIndex : ?Nat) : Bool{
        let txIndex_ = Option.get(_txIndex, txIndex);
        switch(Trie.get(sendingBTC, keyn(txIndex_), Nat.equal)){
            case(?(item)){
                return item.destinations.size() > 0;
            };
            case(_){ return false; };
        };
    };

    // Public methds
    public shared(msg) func get_btc_address(_sa : { subaccount : ?[Nat8] }): async Text{
        assert(_notPaused() or _onlyOwner(msg.caller));
        let accountId = _accountId(msg.caller, _sa.subaccount);
        var own_public_key : [Nat8] = [];
        try{
            countAsyncMessage += 2;
            let ecdsa_public_key = await ic.ecdsa_public_key({
                canister_id = null;
                derivation_path = [ accountId ];
                key_id = { curve = #secp256k1; name = KEY_NAME }; //dfx_test_key
            });
            own_public_key := Blob.toArray(ecdsa_public_key.public_key);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage); 
        };
        let own_address = _public_key_to_p2pkh_address(own_public_key);
        return own_address
        // // Fetch the public key of the given derivation path.
        // let public_key = await EcdsaApi.ecdsa_public_key(key_name, Array.map(derivation_path, Blob.fromArray));
        // // Compute the address.
        // public_key_to_p2pkh_address(network, Blob.toArray(public_key))
    };
    
    public shared(msg) func update_balance(_sa : { subaccount : ?[Nat8] }): async {
        #Ok : Minter.UpdateBalanceResult; // { block_index : Nat64; amount : Nat64 }
        #Err : Minter.UpdateBalanceError;
      }
      {
        assert(_notPaused() or _onlyOwner(msg.caller));
        let __start = Time.now();
        let accountId = _accountId(msg.caller, _sa.subaccount);
        let icrc1Account : ICRC1.Account = { owner = msg.caller; subaccount = _toSaBlob(_sa.subaccount); };
        let account : Minter.Account = { owner = msg.caller; subaccount = _sa.subaccount; };
        var own_address : Text = "";
        if (not(_checkAsyncMessageLimit())){
            countRejections += 1; 
            return #Err(#TemporarilyUnavailable("405: IC network is busy, please try again later.")); 
        };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({error_code = 400; error_message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        // latestVisitTime := Trie.put(latestVisitTime, keyp(msg.caller), Principal.equal, _now()).0;
        _setLatestVisitTime(msg.caller);
        // {
        //     utxos : [Utxo];
        //     tip_block_hash : BlockHash;
        //     tip_height : Nat32;
        //     next_page : ?Page; // 1000 utxos per Page
        // }
        var amount : Nat64 = 0;
        var utxos : [Utxo] = [];
        try {
            countAsyncMessage += 2;
            let res = await _fetchAccountUtxos(?account);
            own_address := res.0;
            amount := res.1;
            utxos := res.2;
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            return #Err(#TemporarilyUnavailable(Error.message(e)))
        };
        if (utxos.size() > 0){
            // mint icBTC
            let saga = _getSaga();
            let toid : Nat = saga.create("mint", #Forward, ?accountId, null);
            let args : ICRC1.TransferArgs = {
                from_subaccount = null;
                to = icrc1Account;
                amount = Nat64.toNat(amount);
                fee = null;
                memo = ?Text.encodeUtf8(own_address);
                created_at_time = null; // nanos
            };
            let task = _buildTask(null, icBTC_, #ICRC1(#icrc1_transfer(args)), [], 0);
            let ttid = saga.push(toid, task, null, null);
            saga.close(toid);
            totalBtcReceiving += amount;
            // record event
            let event : Minter.Event = #received_utxos({ to_account  = account; utxos = _toUtxosArr(utxos) });
            blockEvents := Trie.put(blockEvents, keyn(Nat64.toNat(blockIndex)), Nat.equal, event).0;
            blockIndex += 1;
            // let sagaRes = await saga.run(toid);
            if (toid > 0 and _asyncMessageSize() < 360){ 
                lastSagaRunningTime := Time.now();
                try{
                    countAsyncMessage += 2;
                    let sagaRes = await saga.run(toid);
                    countAsyncMessage -= Nat.min(2, countAsyncMessage);
                }catch(e){
                    countAsyncMessage -= Nat.min(2, countAsyncMessage); 
                };
            }; 
            lastExecutionDuration := Time.now() - __start;
            if (lastExecutionDuration > maxExecutionDuration) { maxExecutionDuration := lastExecutionDuration };
            return #Ok({ block_index = blockIndex - 1; amount = amount });
        }else{
            return #Err(#NoNewUtxos);
        };
    };
    // icrc1_transfer '(record{from_subaccount=null;to=record{owner=principal ""; subaccount= };amount= ;fee=null;memo=null;created_at_time=null})'
    public shared(msg) func get_withdrawal_account() : async Minter.Account{
        assert(_notPaused() or _onlyOwner(msg.caller));
        let accountId = _accountId(msg.caller, null);
        //update fee
        if (Time.now() > lastUpdateFeeTime + 4*3600*ns_){
            lastUpdateFeeTime := Time.now();
            btcFee := await _getBtcFee();
            if (icBTCFee == 0){
                icBTCFee := await icBTC.icrc1_fee();
            };
        };
        return {owner=Principal.fromActor(this); subaccount=?Blob.toArray(accountId)};
    };
    public shared(msg) func retrieve_btc(args: Minter.RetrieveBtcArgs) : async { //{ address : Text; amount : Nat64 }
        #Ok : Minter.RetrieveBtcOk; //{ block_index : Nat64 };
        #Err : Minter.RetrieveBtcError;
      }{
        assert(_notPaused() or _onlyOwner(msg.caller));
        let accountId = _accountId(msg.caller, null);
        let retrieveIcrc1Account: ICRC1.Account = {owner=Principal.fromActor(this); subaccount=?accountId};
        let retrieveAccount : Minter.Account = { owner = msg.caller; subaccount = ?Blob.toArray(accountId); };
        if (not(_checkAsyncMessageLimit())){
            countRejections += 1; 
            return #Err(#TemporarilyUnavailable("405: IC network is busy, please try again later.")); 
        };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({error_code = 400; error_message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        // latestVisitTime := Trie.put(latestVisitTime, keyp(msg.caller), Principal.equal, _now()).0;
        _setLatestVisitTime(msg.caller);
        //update fee
        if (Time.now() > lastUpdateFeeTime + 4*3600*ns_){
            lastUpdateFeeTime := Time.now();
            btcFee := await _getBtcFee();
            if (icBTCFee == 0){
                icBTCFee := await icBTC.icrc1_fee();
            };
        };
        // fetch minter_address
        if (minter_address == ""){
            let res = await _fetchAccountAddress([]);
            minter_public_key := res.0;
            minter_address := res.1;
        };
        //update minter otxos
        if (args.amount >= minterRemainingBalance * 9 / 10 or Time.now() > lastFetchUtxosTime + 4*3600*ns_){
            lastFetchUtxosTime := Time.now();
            ignore await _fetchAccountUtxos(null);
        };
        //MalformedAddress
        switch(Address.scriptPubKey(#p2pkh(args.address))){
            case(#ok(pub_key)){};
            case(#err(msg)){
                return #Err(#MalformedAddress(msg));
            };
        };
        //AmountTooLow
        if (args.amount < Nat64.max(BTC_MIN_AMOUNT, btcFee * AVG_TX_BYTES / 1000)){
            return #Err(#AmountTooLow(Nat64.max(BTC_MIN_AMOUNT, btcFee * AVG_TX_BYTES / 1000)));
        };
        let balance = await icBTC.icrc1_balance_of(retrieveIcrc1Account);
        //InsufficientFunds
        if (Nat64.fromNat(balance) < args.amount){
            return #Err(#InsufficientFunds({balance = Nat64.fromNat(balance)}));
        };
        //Insufficient BTC available
        if (args.amount > minterRemainingBalance){
            return #Err(#TemporarilyUnavailable("Please try again later as some BTC balance of the smart contract is in unconfirmed status."));
        };
        //burn
        let burnArgs : ICRC1.TransferArgs = {
            from_subaccount = ?accountId;
            to = {owner=Principal.fromActor(this); subaccount=null };
            amount = Nat64.toNat(args.amount); // Nat.sub(Nat64.toNat(args.amount), icBTCFee);
            fee = null;
            memo = ?accountId;
            created_at_time = null; // nanos
        };
        switch(await icBTC.icrc1_transfer(burnArgs)){
            case(#Ok(height)){
                let amount = args.amount - btcFee * AVG_TX_BYTES / 1000; // Satoshi
                totalBtcFee += btcFee * AVG_TX_BYTES / 1000;
                totalBtcSent += amount;
                let thisTxIndex = txIndex;
                let status : Minter.RetrieveStatus = {
                    account = {owner = msg.caller; subaccount = null };
                    retrieveAccount = retrieveAccount;
                    burnedBlockIndex = height;
                    btcAddress = args.address;
                    amount = amount;
                    txIndex = thisTxIndex;
                };
                retrieveBTC := Trie.put(retrieveBTC, keyn(Nat64.toNat(blockIndex)), Nat.equal, status).0;
                // record event
                let event : Minter.Event = #accepted_retrieve_btc_request({
                    received_at = Nat64.fromNat(_now());
                    block_index = blockIndex;
                    address = #p2pkh(Blob.toArray(Text.encodeUtf8(args.address)));
                    amount = amount;
                });
                blockEvents := Trie.put(blockEvents, keyn(Nat64.toNat(blockIndex)), Nat.equal, event).0;
                _pushSendingBtc(thisTxIndex, blockIndex, args.address, amount);
                if (Time.now() > lastTxTime + 600*ns_){
                    lastTxTime := Time.now();
                    ignore _sendBtc(?thisTxIndex);
                    txIndex += 1;
                };
                blockIndex += 1;
                return #Ok({block_index = blockIndex - 1 });
            };
            case(#Err(#InsufficientFunds({ balance }))){
                return #Err(#GenericError({ error_message="417: Insufficient balance when burning token."; error_code = 417 }));
            };
            case(_){
                return #Err(#GenericError({ error_message = "412: Error on burning icBTC"; error_code = 412 }));
            };
        };
      };
    
    public shared(msg) func batch_send(_txIndex: ?Nat) : async Bool{
        assert(_notPaused() or _onlyOwner(msg.caller));
        let txi = Option.get(_txIndex, txIndex);
        if (txi == txIndex and _hasSendingBTC(_txIndex)){
            if (Time.now() > lastTxTime + 600*ns_){
                lastTxTime := Time.now();
                await _sendBtc(?txIndex);
                txIndex += 1;
                return true;
            };
        }else if (_hasSendingBTC(_txIndex)){
            if (not(_checkAsyncMessageLimit())){
                countRejections += 1; 
                return false; 
            };
            if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
                return false;
            };
            // latestVisitTime := Trie.put(latestVisitTime, keyp(msg.caller), Principal.equal, _now()).0;
            _setLatestVisitTime(msg.caller);
            await _sendBtc(_txIndex);
            return true;
        };
        return false;
    };

    public query func retrieve_btc_status(args: { block_index : Nat64; }) : async Minter.RetrieveBtcStatus{
        switch(Trie.get(retrieveBTC, keyn(Nat64.toNat(args.block_index)), Nat.equal)){
            case(?(item)){
                switch(Trie.get(sendingBTC, keyn(item.txIndex), Nat.equal)){
                    case(?(record)){
                        return record.status;
                    };
                    case(_){
                        return #Unknown;
                    };
                };
            };
            case(_){ return #Unknown; };
        };
    };
    public query func retrieveLog(_blockIndex : ?Nat64) : async ?Minter.RetrieveStatus{
        let blockIndex_ = Option.get(_blockIndex, blockIndex);
        switch(Trie.get(retrieveBTC, keyn(Nat64.toNat(blockIndex_)), Nat.equal)){
            case(?(item)){
                return ?item;
            };
            case(_){ return null; };
        };
    };
    public query func sendingLog(_txIndex : ?Nat) : async ?Minter.SendingBtcStatus{
        let txIndex_ = Option.get(_txIndex, txIndex);
        switch(Trie.get(sendingBTC, keyn(txIndex_), Nat.equal)){
            case(?(item)){
                return ?item;
            };
            case(_){ return null; };
        };
    };
    
    public query func debug_sendingBTC(_txIndex : ?Nat) : async ?Text{
        let txIndex_ = Option.get(_txIndex, txIndex);
        switch(Trie.get(sendingBTC, keyn(txIndex_), Nat.equal)){
            case(?(item)){
                let signedTx: [Nat8] = Option.get(item.signedTx, []);
                let transaction = Utils.get_ok(Transaction.fromBytes(Iter.fromArray(signedTx)));
                return ?(debug_show(transaction.id()) # " / " # debug_show(transaction.txInputs.size()) # " / " # debug_show(transaction.txOutputs.size()) # " / " # debug_show(transaction.toBytes()));
            };
            case(_){ return null; };
        };
    };
    public shared(msg) func debug_change_address(): async Text{
        assert(_onlyOwner(msg.caller));
        let res = await _fetchAccountAddress([]);
        return res.1;
    };
    // public shared(msg) func debug_send(dst: Text, amount: Nat64) : async Text{
    //     assert(_onlyOwner(msg.caller));
    //     let accountId = Blob.toArray(_accountId(msg.caller, null));
    //     let txid = await Wallet.send(NETWORK, [accountId], KEY_NAME, dst, amount);
    //     return Utils.bytesToText(txid);
    // };
    public shared(msg) func debug_reSendBTC(_txIndex: Nat, _fee: Nat) : async (){
        assert(_onlyOwner(msg.caller));
        await _reSendBtc(_txIndex, _fee);
    };

    public query func utxos(_address: Address) : async ?(PubKey, DerivationPath, [Utxo]){
        return _getAccountUtxos(_address);
    };
    public query func vaultUtxos() : async (Nat64, [(Address, PubKey, DerivationPath, Utxo)]){
        return (minterRemainingBalance, List.toArray(List.append(minterUtxos.0, List.reverse(minterUtxos.1))));
    };
    
    public query func get_events(args: { start : Nat64; length : Nat64 }) : async [Event]{
        return _getEvents(args.start, args.length);
    };

    public query func stats() : async {
        blockIndex: Nat64;
        txIndex: Nat;
        vaultRemainingBalance: Nat64; // minterRemainingBalance
        totalBtcFee: Nat64;
        totalBtcReceiving: Nat64;
        totalBtcSent: Nat64;
        countAsyncMessage: Nat;
        countRejections : Nat;
    } {
        return {
            blockIndex = blockIndex;
            txIndex = txIndex;
            vaultRemainingBalance = minterRemainingBalance; 
            totalBtcFee = totalBtcFee;
            totalBtcReceiving = totalBtcReceiving;
            totalBtcSent = totalBtcSent;
            countAsyncMessage = countAsyncMessage;
            countRejections = countRejections;
        };
    };

    public query func info() : async {
        enDebug: Bool; // app_debug 
        btcNetwork: Network; //NETWORK
        minConfirmations: Nat32; // MIN_CONFIRMATIONS
        btcMinAmount: Nat64; // BTC_MIN_AMOUNT
        minVisitInterval: Nat; // MIN_VISIT_INTERVAL
        version: Text; // version_
        paused: Bool; // pause
        icBTC: Principal; // icBTC_
        icBTCFee: Nat; // icBTCFee
        btcFee: Nat64; // btcFee / 1000
        btcRetrieveFee: Nat64; // btcFee * AVG_TX_BYTES / 1000
        minter_address : Address;
    }{
        return {
            enDebug = app_debug;
            btcNetwork = NETWORK; //NETWORK
            minConfirmations = MIN_CONFIRMATIONS; // MIN_CONFIRMATIONS
            btcMinAmount = BTC_MIN_AMOUNT; // BTC_MIN_AMOUNT
            minVisitInterval = MIN_VISIT_INTERVAL; // MIN_VISIT_INTERVAL
            version = version_; // version_
            paused = pause; // pause
            icBTC = icBTC_; // icBTC_
            icBTCFee = icBTCFee; // icBTCFee
            btcFee = btcFee / 1000; // btcFee / 1000 Satoshis/Byte
            btcRetrieveFee = btcFee * AVG_TX_BYTES / 1000; // btcFee * AVG_TX_BYTES / 1000
            minter_address = minter_address;
        };
    };

    /* ===========================
      Management section
    ============================== */
    public query func getOwner() : async Principal{  
        return owner;
    };
    public shared(msg) func changeOwner(_newOwner: Principal) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        owner := _newOwner;
        return true;
    };
    public shared(msg) func setPause(_pause: Bool) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        pause := _pause;
        return true;
    };


    /**
    * ICTC Transaction Explorer Interface
    * (Optional) Implement the following interface, which allows you to browse transaction records and execute compensation transactions through a UI interface.
    * https://cmqwp-uiaaa-aaaaj-aihzq-cai.raw.ic0.app/
    */
    // ICTC: management functions
    private stable var ictc_admins: [Principal] = [];
    private func _onlyIctcAdmin(_caller: Principal) : Bool { 
        return Option.isSome(Array.find(ictc_admins, func (t: Principal): Bool{ t == _caller }));
    }; 
    private func _onlyBlocking(_toid: Nat) : Bool{
        /// Saga
        switch(_getSaga().status(_toid)){
            case(?(status)){ return status == #Blocking };
            case(_){ return false; };
        };
        /// 2PC
        // switch(_getTPC().status(_toid)){
        //     case(?(status)){ return status == #Blocking };
        //     case(_){ return false; };
        // };
    };
    public query func ictc_getAdmins() : async [Principal]{
        return ictc_admins;
    };
    public shared(msg) func ictc_addAdmin(_admin: Principal) : async (){
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        if (Option.isNull(Array.find(ictc_admins, func (t: Principal): Bool{ t == _admin }))){
            ictc_admins := Tools.arrayAppend(ictc_admins, [_admin]);
        };
    };
    public shared(msg) func ictc_removeAdmin(_admin: Principal) : async (){
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        ictc_admins := Array.filter(ictc_admins, func (t: Principal): Bool{ t != _admin });
    };

    // SagaTM Scan
    public query func ictc_TM() : async Text{
        return "Saga";
    };
    /// Saga
    public query func ictc_getTOCount() : async Nat{
        return _getSaga().count();
    };
    public query func ictc_getTO(_toid: SagaTM.Toid) : async ?SagaTM.Order{
        return _getSaga().getOrder(_toid);
    };
    public query func ictc_getTOs(_page: Nat, _size: Nat) : async {data: [(SagaTM.Toid, SagaTM.Order)]; totalPage: Nat; total: Nat}{
        return _getSaga().getOrders(_page, _size);
    };
    public query func ictc_getTOPool() : async [(SagaTM.Toid, ?SagaTM.Order)]{
        return _getSaga().getAliveOrders();
    };
    public query func ictc_getTT(_ttid: SagaTM.Ttid) : async ?SagaTM.TaskEvent{
        return _getSaga().getActuator().getTaskEvent(_ttid);
    };
    public query func ictc_getTTByTO(_toid: SagaTM.Toid) : async [SagaTM.TaskEvent]{
        return _getSaga().getTaskEvents(_toid);
    };
    public query func ictc_getTTs(_page: Nat, _size: Nat) : async {data: [(SagaTM.Ttid, SagaTM.TaskEvent)]; totalPage: Nat; total: Nat}{
        return _getSaga().getActuator().getTaskEvents(_page, _size);
    };
    public query func ictc_getTTPool() : async [(SagaTM.Ttid, SagaTM.Task)]{
        let pool = _getSaga().getActuator().getTaskPool();
        let arr = Array.map<(SagaTM.Ttid, SagaTM.Task), (SagaTM.Ttid, SagaTM.Task)>(pool, 
        func (item:(SagaTM.Ttid, SagaTM.Task)): (SagaTM.Ttid, SagaTM.Task){
            (item.0, item.1);
        });
        return arr;
    };
    public query func ictc_getTTErrors(_page: Nat, _size: Nat) : async {data: [(Nat, SagaTM.ErrorLog)]; totalPage: Nat; total: Nat}{
        return _getSaga().getActuator().getErrorLogs(_page, _size);
    };
    public query func ictc_getCalleeStatus(_callee: Principal) : async ?SagaTM.CalleeStatus{
        return _getSaga().getActuator().calleeStatus(_callee);
    };

    // Transaction Governance
    public shared(msg) func ictc_clearLog(_expiration: ?Int, _delForced: Bool) : async (){ // Warning: Execute this method with caution
        assert(_onlyOwner(msg.caller));
        _getSaga().clear(_expiration, _delForced);
    };
    public shared(msg) func ictc_clearTTPool() : async (){ // Warning: Execute this method with caution
        assert(_onlyOwner(msg.caller));
        _getSaga().getActuator().clearTasks();
    };
    public shared(msg) func ictc_blockTO(_toid: SagaTM.Toid) : async ?SagaTM.Toid{
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        assert(not(_onlyBlocking(_toid)));
        let saga = _getSaga();
        return saga.block(_toid);
    };
    // public shared(msg) func ictc_removeTT(_toid: SagaTM.Toid, _ttid: SagaTM.Ttid) : async ?SagaTM.Ttid{ // Warning: Execute this method with caution
    //     assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
    //     assert(_onlyBlocking(_toid));
    //     let saga = _getSaga();
    //     saga.open(_toid);
    //     let ttid = saga.remove(_toid, _ttid);
    //     saga.close(_toid);
    //     return ttid;
    // };
    public shared(msg) func ictc_appendTT(_businessId: ?Blob, _toid: SagaTM.Toid, _forTtid: ?SagaTM.Ttid, _callee: Principal, _callType: SagaTM.CallType, _preTtids: [SagaTM.Ttid]) : async SagaTM.Ttid{
        // Governance or manual compensation (operation allowed only when a transaction order is in blocking status).
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        assert(_onlyBlocking(_toid));
        let saga = _getSaga();
        saga.open(_toid);
        let taskRequest = _buildTask(_businessId, _callee, _callType, _preTtids, GET_UTXOS_COST_CYCLES);
        //let ttid = saga.append(_toid, taskRequest, null, null);
        let ttid = saga.appendComp(_toid, Option.get(_forTtid, 0), taskRequest, null);
        return ttid;
    };
    /// Try the task again
    public shared(msg) func ictc_redoTT(_toid: SagaTM.Toid, _ttid: SagaTM.Ttid) : async ?SagaTM.Ttid{
        // Warning: proceed with caution!
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        let ttid = saga.redo(_toid, _ttid);
        try{
            countAsyncMessage += 2;
            let r = await saga.run(_toid);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("430: ICTC error: "# Error.message(e)); 
        };
        return ttid;
    };
    /// set status of pending task
    public shared(msg) func ictc_doneTT(_toid: SagaTM.Toid, _ttid: SagaTM.Ttid, _toCallback: Bool) : async ?SagaTM.Ttid{
        // Warning: proceed with caution!
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        try{
            countAsyncMessage += 2;
            let ttid = await* saga.taskDone(_toid, _ttid, _toCallback);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            return ttid;
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("420: internal call error: "# Error.message(e)); 
        };
    };
    /// set status of pending order
    public shared(msg) func ictc_doneTO(_toid: SagaTM.Toid, _status: SagaTM.OrderStatus, _toCallback: Bool) : async Bool{
        // Warning: proceed with caution!
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        saga.close(_toid);
        try{
            countAsyncMessage += 2;
            let res = await* saga.done(_toid, _status, _toCallback);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            return res;
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("420: internal call error: "# Error.message(e)); 
        };
    };
    /// Complete blocking order
    public shared(msg) func ictc_completeTO(_toid: SagaTM.Toid, _status: SagaTM.OrderStatus) : async Bool{
        // After governance or manual compensations, this method needs to be called to complete the transaction order.
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        assert(_onlyBlocking(_toid));
        let saga = _getSaga();
        saga.close(_toid);
        try{
            countAsyncMessage += 2;
            let r = await saga.run(_toid);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("430: ICTC error: "# Error.message(e)); 
        };
        try{
            countAsyncMessage += 2;
            let r = await* _getSaga().complete(_toid, _status);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            return r;
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("430: ICTC error: "# Error.message(e)); 
        };
    };
    public shared(msg) func ictc_runTO(_toid: SagaTM.Toid) : async ?SagaTM.OrderStatus{
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        saga.close(_toid);
        try{
            countAsyncMessage += 2;
            let r = await saga.run(_toid);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            return r;
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("430: ICTC error: "# Error.message(e)); 
        };
    };
    public shared(msg) func ictc_runTT() : async Bool{ 
        // There is no need to call it normally, but can be called if you want to execute tasks in time when a TO is in the Doing state.
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller) or _notPaused());
        if (not(_checkAsyncMessageLimit())){
            throw Error.reject("405: IC network is busy, please try again later."); 
        };
        // _sessionPush(msg.caller);
        let saga = _getSaga();
        if (_onlyOwner(msg.caller)){
            try{
                countAsyncMessage += 3;
                let res = await* saga.getActuator().run();
                countAsyncMessage -= Nat.min(3, countAsyncMessage);
            }catch(e){
                countAsyncMessage -= Nat.min(3, countAsyncMessage);
                throw Error.reject("430: ICTC error: "# Error.message(e)); 
            };
        } else if (Time.now() > lastSagaRunningTime + ICTC_RUN_INTERVAL*ns_){ 
            lastSagaRunningTime := Time.now();
            try{
                countAsyncMessage += 3;
                let sagaRes = await saga.run(0);
                countAsyncMessage -= Nat.min(3, countAsyncMessage);
            }catch(e){
                countAsyncMessage -= Nat.min(3, countAsyncMessage);
                throw Error.reject("430: ICTC error: "# Error.message(e)); 
            };
        };
        return true;
    };
    /**
    * End: ICTC Transaction Explorer Interface
    */

    /* ===========================
      DRC207 section
    ============================== */
    public query func drc207() : async DRC207.DRC207Support{
        return {
            monitorable_by_self = false;
            monitorable_by_blackhole = { allowed = true; canister_id = ?Principal.fromText("7hdtw-jqaaa-aaaak-aaccq-cai"); };
            cycles_receivable = true;
            timer = { enable = false; interval_seconds = null; }; 
        };
    };
    /// canister_status
    // public shared(msg) func canister_status() : async DRC207.canister_status {
    //     // _sessionPush(msg.caller);
    //     // if (_tps(15, null).1 > setting.MAX_TPS*5 or _tps(15, ?msg.caller).0 > 2){ 
    //     //     assert(false); 
    //     // };
    //     let ic : DRC207.IC = actor("aaaaa-aa");
    //     await ic.canister_status({ canister_id = Principal.fromActor(this) });
    // };
    // receive cycles
    public func wallet_receive(): async (){
        let amout = Cycles.available();
        let accepted = Cycles.accept(amout);
    };
    /// timer tick
    // public shared(msg) func timer_tick(): async (){
    //     //
    // };

    /* ===========================
      Upgrade section
    ============================== */
    private stable var __sagaDataNew: ?SagaTM.Data = null;
    system func preupgrade() {
        let data = _getSaga().getData();
        __sagaDataNew := ?data;
        // assert(List.size(data.actuator.tasks.0) == 0 and List.size(data.actuator.tasks.1) == 0);
    };
    system func postupgrade() {
        switch(__sagaDataNew){
            case(?(data)){
                _getSaga().setData(data);
                __sagaDataNew := null;
            };
            case(_){};
        };
    };

};