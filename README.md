# supplychain-smart-contract

This repository contains the Solidity smart contracts developed as part of an
MSc thesis titled:

**"Design and Implementation of a Blockchain-Based Decentralized Supply Chain
Management System"**

## Overview
The smart contracts are designed to manage core on-chain logic of a decentralized
supply chain system, ensuring transparency, immutability, and traceability of
critical supply chain data.

The system follows a hybrid architecture consisting of:
- Blockchain layer (Ethereum – Sepolia test network)
- Decentralized storage layer (IPFS)
- Off-chain layer for temporary and interactive data
- Web-based user interface

## Smart Contracts
- **RoleManager.sol**  
  Manages access control and role-based permissions.

- **ProductManager.sol**  
  Handles product registration, status updates, and lifecycle tracking.

## Design Principles
- Only critical and immutable data are stored on-chain
- Large files and metadata are stored on IPFS, with only CIDs recorded on-chain
- No direct interaction between off-chain server and blockchain

## Network
- Ethereum Sepolia Test Network

## Disclaimer
These contracts are developed for academic and research purposes and have not
been audited for production use.
