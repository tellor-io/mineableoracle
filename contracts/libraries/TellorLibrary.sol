pragma solidity >=0.5.0 <0.7.0;

import "./SafeMath.sol";
import "./Utilities.sol";
import "./TellorStorage.sol";
import "./TellorTransfer.sol";
import "./TellorDispute.sol";
import "./TellorStake.sol";
import "./TellorGettersLibrary.sol";

/**
 * @title Tellor Oracle System Library
 * @dev Contains the functions' logic for the Tellor contract where miners can submit the proof of work
 * along with the value and smart contracts can requestData and tip miners.
 */
library TellorLibrary {
    using SafeMath for uint256;

    event TipAdded(address indexed _sender, uint256 indexed _requestId, uint256 _tip, uint256 _totalTips);
    //Emits upon someone adding value to a pool; msg.sender, amount added, and timestamp incentivized to be mined
    event DataRequested(
        address indexed _sender,
        string _query,
        string _querySymbol,
        uint256 _granularity,
        uint256 indexed _requestId,
        uint256 _totalTips
    );
    //emits when a new challenge is created (either on mined block or when a new request is pushed forward on waiting system)
    event NewChallenge(
        bytes32 _currentChallenge,
        uint256 indexed _currentRequestId,
        uint256 _difficulty,
        uint256 _multiplier,
        string _query,
        uint256 _totalTips
    );
    //emits when a the payout of another request is higher after adding to the payoutPool or submitting a request
    event NewRequestOnDeck(uint256 indexed _requestId, string _query, bytes32 _onDeckQueryHash, uint256 _onDeckTotalTips);
    //Emits upon a successful Mine, indicates the blocktime at point of the mine and the value mined
    event NewValue(uint256 indexed _requestId, uint256 _time, uint256 _value, uint256 _totalTips, bytes32 _currentChallenge);
    //Emits upon each mine (5 total) and shows the miner, nonce, and value submitted
    event NonceSubmitted(address indexed _miner, string _nonce, uint256 indexed _requestId, uint256 _value, bytes32 _currentChallenge);
    event OwnershipTransferred(address indexed _previousOwner, address indexed _newOwner);
    event OwnershipProposed(address indexed _previousOwner, address indexed _newOwner);

    /*Functions*/

    /*This is a cheat for demo purposes, will delete upon actual launch*/
    // function theLazyCoon(TellorStorage.TellorStorageStruct storage self,address _address, uint _amount) public {
    //     self.uintVars[keccak256("total_supply")] += _amount;
    //     TellorTransfer.updateBalanceAtNow(self.balances[_address],_amount);
    // } 

    /**
    * @dev Add tip to Request value from oracle
    * @param _requestId being requested to be mined
    * @param _tip amount the requester is willing to pay to be get on queue. Miners
    * mine the onDeckQueryHash, or the api with the highest payout pool
    */
    function addTip(TellorStorage.TellorStorageStruct storage self, uint256 _requestId, uint256 _tip) public {
        require(_requestId > 0, "RequestId is 0");
        require(_requestId <= self.uintVars[keccak256("requestCount")], "RequestId is not less than count");

        //If the tip > 0 transfer the tip to this contract
        if (_tip > 0) {
            TellorTransfer.doTransfer(self, msg.sender, address(this), _tip);
        }

        //Update the information for the request that should be mined next based on the tip submitted
        updateOnDeck(self, _requestId, _tip);
        emit TipAdded(msg.sender, _requestId, _tip, self.requestDetails[_requestId].apiUintVars[keccak256("totalTip")]);
    }



   /**
    * @dev This fucntion is called by submitMiningSolution and adjusts the difficulty, sorts and stores the first
    * 5 values received, pays the miners, the dev share and assigns a new challenge
    * @param _nonce or solution for the PoW  for the requestId
    * @param _requestId for the current request being mined
    */
    function newBlock(TellorStorage.TellorStorageStruct storage self, string memory _nonce, uint256 _requestId) internal {
        TellorStorage.Request storage _request = self.requestDetails[_requestId];

        // If the difference between the timeTarget and how long it takes to solve the challenge this updates the challenge
        //difficulty up or donw by the difference between the target time and how long it took to solve the prevous challenge
        //otherwise it sets it to 1
        int256 _change = int256(SafeMath.min(1200, (now - self.uintVars[keccak256("timeOfLastNewValue")])));
        _change = (int256(self.uintVars[keccak256("difficulty")]) * (int256(self.uintVars[keccak256("timeTarget")]) - _change)) / 4000;

        if (_change < 2 && _change > -2) {
            if (_change >= 0) {
                _change = 1;
            } else {
                _change = -1;
            }
        }

        if ((int256(self.uintVars[keccak256("difficulty")]) + _change) <= 0) {
            self.uintVars[keccak256("difficulty")] = 1;
        } else {
            self.uintVars[keccak256("difficulty")] = uint256(int256(self.uintVars[keccak256("difficulty")]) + _change);
        }

        //Sets time of value submission rounded to 1 minute
        uint256 _timeOfLastNewValue = now - (now % 1 minutes);
        self.uintVars[keccak256("timeOfLastNewValue")] = _timeOfLastNewValue;

        //update Miner's last award time
        self.uintVars[keccak256(abi.encodePacked(msg.sender))] = _timeOfLastNewValue;

        //The sorting algorithm that sorts the values of the first five values that come in
        TellorStorage.Details[5] memory a = self.currentMiners;
        uint256 i;
        for (i = 1; i < 5; i++) {
            uint256 temp = a[i].value;
            address temp2 = a[i].miner;
            uint256 j = i;
            while (j > 0 && temp < a[j - 1].value) {
                a[j].value = a[j - 1].value;
                a[j].miner = a[j - 1].miner;
                j--;
            }
            if (j < i) {
                a[j].value = temp;
                a[j].miner = temp2;
            }
        }

        //Pay the miners 
        //adjust by payout = payout * ratio 0.000030612633181126/1e18  
        //uint _currentReward = self.uintVars[keccak256("currentReward")];   
        if(self.uintVars[keccak256("currentReward")] == 0){
            self.uintVars[keccak256("currentReward")] = 5e18;
        }
        if (self.uintVars[keccak256("currentReward")] > 1e18) {
        self.uintVars[keccak256("currentReward")] = self.uintVars[keccak256("currentReward")] - self.uintVars[keccak256("currentReward")] * 30612633181126/1e18; 
        self.uintVars[keccak256("devShare")] = self.uintVars[keccak256("currentReward")] * 50/100;
        } else {
            self.uintVars[keccak256("currentReward")] = 1e18;
        }


        //update the total supply
        self.uintVars[keccak256("total_supply")] +=  self.uintVars[keccak256("devShare")] + self.uintVars[keccak256("currentReward")]*5 - (self.uintVars[keccak256("currentTotalTips")] * 10/100);
    
        //Burn some tips???
        self.uintVars[keccak256("currentTotalTips")] = self.uintVars[keccak256("currentTotalTips")] * 90/100;
        //transfer to zero address
        TellorTransfer.doTransfer(self, address(this), address(0x0), self.uintVars[keccak256("currentTotalTips")] * 10/100 );
        

        emit NewValue(
            _requestId,
            _timeOfLastNewValue,
            a[2].value,
            self.uintVars[keccak256("currentTotalTips")] - (self.uintVars[keccak256("currentTotalTips")] % 5),
            self.currentChallenge
        );

        for (i = 0; i < 5; i++) {
            TellorTransfer.doTransfer(self, address(this), a[i].miner, self.uintVars[keccak256("currentReward")]  + self.uintVars[keccak256("currentTotalTips")] / 5);
            
        }

    //pay the dev-share
        TellorTransfer.doTransfer(self, address(this), self.addressVars[keccak256("_owner")],  self.uintVars[keccak256("devShare")]); //The ten there is the devshare
        //Save the official(finalValue), timestamp of it, 5 miners and their submitted values for it, and its block number
        _request.finalValues[_timeOfLastNewValue] = a[2].value;
        _request.requestTimestamps.push(_timeOfLastNewValue);
        //these are miners by timestamp
        _request.minersByValue[_timeOfLastNewValue] = [a[0].miner, a[1].miner, a[2].miner, a[3].miner, a[4].miner];
        _request.valuesByTimestamp[_timeOfLastNewValue] = [a[0].value, a[1].value, a[2].value, a[3].value, a[4].value];
        _request.minedBlockNum[_timeOfLastNewValue] = block.number;
        //map the timeOfLastValue to the requestId that was just mined
        self.requestIdByTimestamp[_timeOfLastNewValue] = _requestId;
        //add timeOfLastValue to the newValueTimestamps array
        self.newValueTimestamps.push(_timeOfLastNewValue);
        //re-start the count for the slot progress to zero before the new request mining starts
        self.uintVars[keccak256("slotProgress")] = 0;
        uint256 _topId = TellorGettersLibrary.getTopRequestID(self);
        self.uintVars[keccak256("currentRequestId")] = _topId;
        //if the currentRequestId is not zero(currentRequestId exists/something is being mined) select the requestId with the hightest payout
        //else wait for a new tip to mine
        if (_topId > 0) {
            //Update the current request to be mined to the requestID with the highest payout
            self.uintVars[keccak256("currentTotalTips")] = self.requestDetails[_topId].apiUintVars[keccak256("totalTip")];
            //Remove the currentRequestId/onDeckRequestId from the requestQ array containing the rest of the 50 requests
            self.requestQ[self.requestDetails[_topId].apiUintVars[keccak256("requestQPosition")]] = 0;

            //unmap the currentRequestId/onDeckRequestId from the requestIdByRequestQIndex
            self.requestIdByRequestQIndex[self.requestDetails[_topId].apiUintVars[keccak256("requestQPosition")]] = 0;

            //Remove the requestQposition for the currentRequestId/onDeckRequestId since it will be mined next
            self.requestDetails[_topId].apiUintVars[keccak256("requestQPosition")] = 0;

            //Reset the requestId TotalTip to 0 for the currentRequestId/onDeckRequestId since it will be mined next
            //and the tip is going to the current timestamp miners. The tip for the API needs to be reset to zero
            self.requestDetails[_topId].apiUintVars[keccak256("totalTip")] = 0;

            //gets the max tip in the in the requestQ[51] array and its index within the array??
            uint256 newRequestId = TellorGettersLibrary.getTopRequestID(self);
            //Issue the the next challenge
            self.currentChallenge = keccak256(abi.encodePacked(_nonce, self.currentChallenge, blockhash(block.number - 1))); // Save hash for next proof
            emit NewChallenge(
                self.currentChallenge,
                _topId,
                self.uintVars[keccak256("difficulty")],
                self.requestDetails[_topId].apiUintVars[keccak256("granularity")],
                self.requestDetails[_topId].queryString,
                self.uintVars[keccak256("currentTotalTips")]
            );
            emit NewRequestOnDeck(
                newRequestId,
                self.requestDetails[newRequestId].queryString,
                self.requestDetails[newRequestId].queryHash,
                self.requestDetails[newRequestId].apiUintVars[keccak256("totalTip")]
            );
        } else {
            self.uintVars[keccak256("currentTotalTips")] = 0;
            self.currentChallenge = "";
        }
    }

    /**
    * @dev Proof of work is called by the miner when they submit the solution (proof of work and value)
    * @param _nonce uint submitted by miner
    * @param _requestId the apiId being mined
    * @param _value of api query
    */
    function submitMiningSolution(TellorStorage.TellorStorageStruct storage self, string memory _nonce, uint256 _requestId, uint256 _value)
        public
    {
        //require miner is staked
        require(self.stakerDetails[msg.sender].currentStatus == 1, "Miner status is not staker");

        //Check the miner is submitting the pow for the current request Id
        require(_requestId == self.uintVars[keccak256("currentRequestId")], "RequestId is wrong");

        //Saving the challenge information as unique by using the msg.sender
        require(
            uint256(
                sha256(abi.encodePacked(ripemd160(abi.encodePacked(keccak256(abi.encodePacked(self.currentChallenge, msg.sender, _nonce))))))
            ) %
                self.uintVars[keccak256("difficulty")] ==
                0,
            "Incorrect nonce for current challenge"
        );

        //Make sure the miner does not submit a value more than once
        require(self.minersByChallenge[self.currentChallenge][msg.sender] == false, "Miner already submitted the value");

        //require the miner did not receive awards in the last hour
        require(now - self.uintVars[keccak256(abi.encodePacked(msg.sender))] > 1 hours);



        //Save the miner and value received
        self.currentMiners[self.uintVars[keccak256("slotProgress")]].value = _value;
        self.currentMiners[self.uintVars[keccak256("slotProgress")]].miner = msg.sender;

        //Add to the count how many values have been submitted, since only 5 are taken per request
        self.uintVars[keccak256("slotProgress")]++;

        //Update the miner status to true once they submit a value so they don't submit more than once
        self.minersByChallenge[self.currentChallenge][msg.sender] = true;

        emit NonceSubmitted(msg.sender, _nonce, _requestId, _value, self.currentChallenge);

        //If 5 values have been received, adjust the difficulty otherwise sort the values until 5 are received
        if (self.uintVars[keccak256("slotProgress")] == 5) {
            newBlock(self, _nonce, _requestId);
        }
    }

    /**
    * @dev Allows the current owner to propose transfer control of the contract to a
    * newOwner and the ownership is pending until the new owner calls the claimOwnership
    * function
    * @param _pendingOwner The address to transfer ownership to.
    */
    function proposeOwnership(TellorStorage.TellorStorageStruct storage self, address payable _pendingOwner) internal {
        require(msg.sender == self.addressVars[keccak256("_owner")], "Sender is not owner");
        emit OwnershipProposed(self.addressVars[keccak256("_owner")], _pendingOwner);
        self.addressVars[keccak256("pending_owner")] = _pendingOwner;
    }

    /**
    * @dev Allows the new owner to claim control of the contract
    */
    function claimOwnership(TellorStorage.TellorStorageStruct storage self) internal {
        require(msg.sender == self.addressVars[keccak256("pending_owner")], "Sender is not pending owner");
        emit OwnershipTransferred(self.addressVars[keccak256("_owner")], self.addressVars[keccak256("pending_owner")]);
        self.addressVars[keccak256("_owner")] = self.addressVars[keccak256("pending_owner")];
    }

    /**
    * @dev This function updates APIonQ and the requestQ when requestData or addTip are ran
    * @param _requestId being requested
    * @param _tip is the tip to add
    */
    function updateOnDeck(TellorStorage.TellorStorageStruct storage self, uint256 _requestId, uint256 _tip) internal {
        TellorStorage.Request storage _request = self.requestDetails[_requestId];
        uint256 onDeckRequestId = TellorGettersLibrary.getTopRequestID(self);
        //If the tip >0 update the tip for the requestId
        if (_tip > 0) {
            _request.apiUintVars[keccak256("totalTip")] = _request.apiUintVars[keccak256("totalTip")].add(_tip);
        }
        //Set _payout for the submitted request
        uint256 _payout = _request.apiUintVars[keccak256("totalTip")];

        //If there is no current request being mined
        //then set the currentRequestId to the requestid of the requestData or addtip requestId submitted,
        // the totalTips to the payout/tip submitted, and issue a new mining challenge
        if (self.uintVars[keccak256("currentRequestId")] == 0) {
            _request.apiUintVars[keccak256("totalTip")] = 0;
            self.uintVars[keccak256("currentRequestId")] = _requestId;
            self.uintVars[keccak256("currentTotalTips")] = _payout;
            self.currentChallenge = keccak256(abi.encodePacked(_payout, self.currentChallenge, blockhash(block.number - 1))); // Save hash for next proof
            emit NewChallenge(
                self.currentChallenge,
                self.uintVars[keccak256("currentRequestId")],
                self.uintVars[keccak256("difficulty")],
                self.requestDetails[self.uintVars[keccak256("currentRequestId")]].apiUintVars[keccak256("granularity")],
                self.requestDetails[self.uintVars[keccak256("currentRequestId")]].queryString,
                self.uintVars[keccak256("currentTotalTips")]
            );
        } else {
            //If there is no OnDeckRequestId
            //then replace/add the requestId to be the OnDeckRequestId, queryHash and OnDeckTotalTips(current highest payout, aside from what
            //is being currently mined)
            if (_payout > self.requestDetails[onDeckRequestId].apiUintVars[keccak256("totalTip")] || (onDeckRequestId == 0)) {
                //let everyone know the next on queue has been replaced
                emit NewRequestOnDeck(_requestId, _request.queryString, _request.queryHash, _payout);
            }

            //if the request is not part of the requestQ[51] array
            //then add to the requestQ[51] only if the _payout/tip is greater than the minimum(tip) in the requestQ[51] array
            if (_request.apiUintVars[keccak256("requestQPosition")] == 0) {
                uint256 _min;
                uint256 _index;
                (_min, _index) = Utilities.getMin(self.requestQ);
                //we have to zero out the oldOne
                //if the _payout is greater than the current minimum payout in the requestQ[51] or if the minimum is zero
                //then add it to the requestQ array aand map its index information to the requestId and the apiUintvars
                if (_payout > _min || _min == 0) {
                    self.requestQ[_index] = _payout;
                    self.requestDetails[self.requestIdByRequestQIndex[_index]].apiUintVars[keccak256("requestQPosition")] = 0;
                    self.requestIdByRequestQIndex[_index] = _requestId;
                    _request.apiUintVars[keccak256("requestQPosition")] = _index;
                }
                // else if the requestid is part of the requestQ[51] then update the tip for it
            } else if (_tip > 0) {
                self.requestQ[_request.apiUintVars[keccak256("requestQPosition")]] += _tip;
            }
        }
    }
}
