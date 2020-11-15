import { expectRevert } from '@openzeppelin/test-helpers'

import {
  TestCounterInstance,
  ProxyIdentityInstance, ProxyFactoryInstance
} from '../types/truffle-contracts'
import {ProxyFactory} from "@openzeppelin/upgrades";

const ProxyIdentity = artifacts.require('ProxyIdentity')
const ProxyFactory = artifacts.require('ProxyFactory')
const Counter = artifacts.require('TestCounter')

const OPERATION_CALL = 0

contract('ProxyIdentity', function (accounts) {
  let identity: ProxyIdentityInstance
  let counter: TestCounterInstance
  let factory: ProxyFactoryInstance

  let saltCounter=0
  before( 'init factory', async()=>{
    factory = await ProxyFactory.new()
  })
  beforeEach(async function () {
    // Deploy contracts
    counter = await Counter.new()
    const ret = await factory.deployProxy(accounts[0],saltCounter++)
    const addr = ret.logs[0].args.proxyAddress
    // const addr = await factory.deployProxy.call(accounts[0])
    identity = await ProxyIdentity.at(addr)
  })

  it('should allow the owner to call execute', async function () {
    // Counter should be 0 initially
    assert.equal((await counter.get()).toString(), '0')

    // Call counter.increment from identity
    const encodedCall = counter.contract.methods.increment().encodeABI()
    await identity.execute(OPERATION_CALL, counter.address, 0, encodedCall, { from: accounts[0] })

    // Check that increment was called
    assert.equal((await counter.get()).toString(), '1')
  })

  it('should not allow non-owner to call execute', async function () {
    // Counter should be 0 initially
    assert.equal((await counter.get()).toString(), '0')

    // Calling counter.increment from identity should fail
    const encodedCall = counter.contract.methods.increment().encodeABI()
    await expectRevert(identity.execute(OPERATION_CALL, counter.address, 0, encodedCall, { from: accounts[1] }), 'ProxyIdentity: caller is not the owner')

    // Check that increment was not called
    assert.equal((await counter.get()).toString(), '0')
  })

  it('should receive ether correctly', async () => {
    // Checking that balance of Identity contract is 0.
    const actualBalance = await web3.eth.getBalance(identity.address)
    assert.equal(actualBalance.toString(), '0')

    // Sending ether to the identity contract.
    await web3.eth.sendTransaction({
      from: accounts[0],
      to: identity.address,
      value: web3.utils.toWei('1', 'ether')
    })

    // Check Identity contract has received the ether.
    const oneEthAmount = await web3.utils.toWei('1', 'ether')
    const identityBalance = await web3.eth.getBalance(identity.address)
    assert.equal(oneEthAmount, identityBalance)
  })

  it('should allow owner to send ether', async () => {
    await web3.eth.sendTransaction({
      from: accounts[0],
      to: identity.address,
      value: web3.utils.toWei('1', 'ether')
    })

    // We have 1 ether
    const oneEthAmount = await web3.utils.toWei('1', 'ether')
    const actualBalance = await web3.eth.getBalance(identity.address)
    assert.equal(actualBalance, oneEthAmount)

    // Sending 1 ether
    await identity.execute(OPERATION_CALL, counter.address, web3.utils.toWei('1', 'ether'), '0x0')

    // We have 0 ether
    const zeroEthAmount = await web3.utils.toWei('0', 'ether')
    const identityBalance = await web3.eth.getBalance(identity.address)
    assert.equal(zeroEthAmount, identityBalance)

    // contract received 1 ether
    const counterBalance = await web3.eth.getBalance(counter.address)
    assert.equal(oneEthAmount, counterBalance)
  })
})
