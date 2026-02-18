# Decentralized Supply Chain Smart Contracts

This repository contains the Solidity smart contracts developed as part of a
**Bachelor’s Thesis** titled:

**“Design and Implementation of a Blockchain-Based Decentralized Supply Chain
Management System”**

## Overview
These smart contracts implement the core **on-chain logic** of a decentralized
supply chain management system, focusing on transparency, immutability, and
traceability of critical supply chain data.

The overall system follows a **hybrid architecture** consisting of:
- Blockchain layer (Ethereum – Sepolia test network)
- Decentralized storage layer (IPFS)
- Off-chain layer for temporary and interactive data
- Web-based user interface

This repository includes **only the blockchain smart contract layer**.

## Smart Contracts
- **RoleManager.sol**  
  Handles role-based access control and permissions.

- **ProductManager.sol**  
  Manages product registration, lifecycle tracking, and status updates across
  the supply chain.

## Design Principles
- Only critical and immutable data are stored on-chain
- Large files and documents are stored on IPFS, with only their CIDs recorded on-chain
- Off-chain server has no direct interaction with the blockchain
- All blockchain interactions are performed via the user interface and user wallets

## Network
- Ethereum Sepolia Test Network

## Disclaimer
These smart contracts are developed for academic purposes as part of a bachelor
thesis and have not been audited for production use.
