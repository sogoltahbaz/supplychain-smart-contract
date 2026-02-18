pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";



library Utils {
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

/* ------------------------------- RoleManager ---------------------------- */
contract RoleManager {
    event RoleAssigned(address indexed account, bytes32 role);
    event RoleRemoved(address indexed account, bytes32 role);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    address[] private _adminList;

    mapping(address => mapping(bytes32 => bool)) private _roles;
    mapping(address => bool) private _roleSelected;
    mapping(address => bool) private _admins;

    bytes32 public constant ADMIN     = keccak256("ADMIN");
    bytes32 public constant SUPPLIER  = keccak256("SUPPLIER");
    bytes32 public constant CUSTOMER  = keccak256("CUSTOMER");

    modifier onlyAdmin() {
    require(_admins[msg.sender], "Only admin can perform this");
    _;
}

constructor() {
    _admins[msg.sender] = true;
    _roles[msg.sender][ADMIN] = true;
    _adminList.push(msg.sender);
    emit RoleAssigned(msg.sender, ADMIN);
}

function getAdmins() external view returns (address[] memory) {
    return _adminList;
}


function selectInitialRole(bytes32 role) external {
    require(!_roleSelected[msg.sender], "Role already selected");  
    require(role == SUPPLIER || role == CUSTOMER, "Invalid role");
    
    _roles[msg.sender][role] = true;
    _roleSelected[msg.sender] = true;
    emit RoleAssigned(msg.sender, role);
}

function hasSelectedRole(address user) external view returns (bool) {
    return _roleSelected[user];
}

function assignRole(address account, bytes32 role) public onlyAdmin {
    require(account != address(0), "Invalid account");

    require(!_roleSelected[account], "Role already selected for this account");
    
    _roles[account][role] = true;
    _roleSelected[account] = true;
    emit RoleAssigned(account, role);
}

function removeRole(address account, bytes32 role) external onlyAdmin {
    require(account != address(0), "Invalid account");

    _roles[account][role] = false;
    _roleSelected[account] = false; 

    emit RoleRemoved(account, role);
}

function hasRole(address account, bytes32 role) public view returns (bool) {
    return _roles[account][role];
}

function getUserRole(address account) external view returns (bytes32) {
    if (_roles[account][ADMIN]) return ADMIN;
    if (_roles[account][SUPPLIER]) return SUPPLIER;
    if (_roles[account][CUSTOMER]) return CUSTOMER;
    return bytes32(0);  
}

function isAdmin(address account) external view returns (bool) {
    return _admins[account];
}

function addAdmin(address newAdmin) external onlyAdmin {
    require(newAdmin != address(0), "Invalid admin");
    require(!_admins[newAdmin], "Already admin");

    _admins[newAdmin] = true;
    _roles[newAdmin][ADMIN] = true;
    _adminList.push(newAdmin); 

    emit RoleAssigned(newAdmin, ADMIN);
}
}

/* ------------------------------ ProductManager -------------------------- */
contract ProductManager is RoleManager {
    event ProductCreated(uint256 indexed productId, string name, address indexed owner);
    event ProductTransferred(uint256 indexed productId, address indexed from, address indexed to);
    event ProductStatusUpdated(uint256 indexed productId, string status);
    event ProductVerified(uint256 indexed productId);
    event LocationCheckpoint(uint256 indexed productId, string place, int256 latE6, int256 lonE6, uint256 at);
    event DocAnchored(uint256 indexed productId, bytes32 docHash, string docType);
    event StorageConditionsUpdated(uint256 indexed productId, string conditions);

    error NotAuthorized();
    error ProductNotFound();
    error InvalidTransition();

    struct StatusRecord {
        string status;
        uint256 timestamp;
        address updatedBy;
    }

    struct Product {
        string name;
        address owner;
        uint256 price;
        address previousOwner;
        address finalCustomer; 
        uint256 expiryDate;
        string currentStatus;
        StatusRecord[] statusHistory;
        bool verified;
        string storageConditions; 
        address originalOwner; 
        address returnedToOriginalAddr;
    }

    struct LocationRecord {
        string place;
        int256 latE6;
        int256 lonE6;
        uint256 timestamp;
        address reportedBy;
    }

    enum Lifecycle { 
        Created, 
        Packed, 
        ShippedToSupplier, 
        ShippedToCustomer, 
        ReceivedBySupplier, 
        DeliveredToCustomer, 
        Returned, 
        Expired
    }

    struct TransactionRecord {
        uint256 productId;
        address actor;
        string action;
        string statusAt;
        uint256 timestamp;
        address from;
        address to;
    }

    TransactionRecord[] private _history;

    function _logTransaction(uint256 _pid, string memory _action, address _from, address _to) internal {
        _history.push(TransactionRecord({
            productId: _pid,
            actor: msg.sender,
            action: _action,
            statusAt: _products[_pid].currentStatus,
            timestamp: block.timestamp,
            from: _from,
            to: _to
        }));
    }

    function getFullHistory() external view returns (TransactionRecord[] memory) {
        return _history;
    }

    mapping(uint256 => Product) internal _products;
    mapping(address => uint256[]) internal _ownerProducts;
    mapping(uint256 => LocationRecord[]) internal _route;
    mapping(uint256 => Lifecycle) public lifecycle;
    mapping(uint256 => bytes32[]) public productDocs;

    uint256 internal _nextProductId = 1;

    modifier onlyOwnerSupplierAdmin(uint256 productId) {
        if (
            _products[productId].owner != msg.sender &&
            !hasRole(msg.sender, SUPPLIER) &&
            !hasRole(msg.sender, ADMIN)
        ) revert NotAuthorized();
        _;
    }

    modifier onlyCustomerOrAdmin() {
        if (!hasRole(msg.sender, CUSTOMER) && !hasRole(msg.sender, ADMIN)) revert NotAuthorized();
        _;
    }

    function createProduct(
        string calldata name,
        uint256 price,
        uint256 expiryDate
    ) public returns (uint256) {
        require(bytes(name).length > 0, "Product name cannot be empty");
        require(expiryDate == 0 || expiryDate > block.timestamp, "Invalid expiryDate");

        uint256 productId = _nextProductId++;
        Product storage newProduct = _products[productId];
        newProduct.name = name;
        newProduct.owner = msg.sender;
        newProduct.price = price;
        newProduct.expiryDate = expiryDate;
        newProduct.currentStatus = "Created";
        newProduct.verified = false;
        newProduct.storageConditions = ""; 
        newProduct.originalOwner = msg.sender; 
        newProduct.statusHistory.push(
            StatusRecord({ status: "Created", timestamp: block.timestamp, updatedBy: msg.sender })
        );

        _ownerProducts[msg.sender].push(productId);
        lifecycle[productId] = Lifecycle.Created;

        emit ProductCreated(productId, name, msg.sender);
        emit ProductStatusUpdated(productId, "Created");
        _logTransaction(productId, "Creation", address(0), msg.sender);
        return productId;
    }

    function getStorageConditions(uint256 productId) external view returns (string memory) {
        if (_products[productId].owner == address(0)) revert ProductNotFound();
        return _products[productId].storageConditions;
    }
    mapping(address => uint256) public userBalances;
    function getUserBalance(address user) public view returns (uint256) {
        return userBalances[user];
    }

    function updateProductStatus(uint256 productId, string calldata status) public {
        if (_products[productId].owner == address(0)) revert ProductNotFound();
        
        (bool ok, Lifecycle next) = _statusToLifecycle(status, msg.sender);
        require(ok, "Status not allowed for your role");
        
        if (!_isValidTransition(productId, next)) revert InvalidTransition();
        
        lifecycle[productId] = next;
        _updateStatus(productId, _lifecycleToString(next), msg.sender);
        _logTransaction(productId, "Status Update", msg.sender, msg.sender);

        if (next == Lifecycle.ReceivedBySupplier || next == Lifecycle.DeliveredToCustomer) {
            Product storage product = _products[productId];
            uint256 amount = product.price;
            address seller = product.previousOwner == address(0) ? product.originalOwner : product.previousOwner;

            require(userBalances[msg.sender] >= amount, "Insufficient balance");
            
            userBalances[msg.sender] -= amount;
            userBalances[seller] += amount;
        }
    }

    mapping(uint256 => mapping(address => uint8)) public ratings; 

    struct RatingInfo {
        uint8 stars;
        bytes32 commentHash;
    }

    mapping(uint256 => mapping(address => RatingInfo)) public productRatings;
    mapping(uint256 => RatingInfo[]) private _allRatings;

    function rateProduct(uint256 productId, uint8 stars, bytes32 commentHash) external {
        require(_products[productId].owner != address(0), "Product not found");
        require(stars >= 1 && stars <= 5, "Stars must be between 1 and 5"); 

        productRatings[productId][msg.sender] = RatingInfo(stars, commentHash);
        _allRatings[productId].push(RatingInfo(stars, commentHash)); 

        emit ProductRated(productId, msg.sender, stars, commentHash);
    }

    function getAverageRating(uint256 productId) external view returns (uint256) {
        RatingInfo[] storage rating = _allRatings[productId];
        if (rating.length == 0) return 0;

        uint256 sum;
        for (uint256 i = 0; i < rating.length; i++) {
            sum += rating[i].stars;
        }
        return sum / rating.length;
    }

    event ProductRated(uint256 indexed productId, address indexed user, uint8 stars, bytes32 commentHash);

    function setLifecycle(uint256 productId, Lifecycle next)
        external
        onlyOwnerSupplierAdmin(productId)
    {
        if (_products[productId].owner == address(0)) revert ProductNotFound();
        _enforceAndSetLifecycle(productId, next, msg.sender);
    }

    function getProduct(uint256 productId) external view returns (
        string memory name,
        address owner,
        uint256 price,
        uint256 expiryDate,
        string memory currentStatus,
        bool verified
    ) {
        Product storage product = _products[productId];
        if (product.owner == address(0)) revert ProductNotFound();
        return (product.name, product.owner, product.price, product.expiryDate, product.currentStatus, product.verified);
    }

    function getProductsByOwner(address owner) external view returns (uint256[] memory) {
        return _ownerProducts[owner];
    }

    function getProductStatusHistory(uint256 productId) external view returns (
        string[] memory statuses,
        uint256[] memory timestamps,
        address[] memory updatedBy
    ) {
        Product storage product = _products[productId];
        uint256 length = product.statusHistory.length;

        statuses = new string[](length);
        timestamps = new uint256[](length);
        updatedBy = new address[](length);

        for (uint i = 0; i < length; i++) {
            StatusRecord storage record = product.statusHistory[i];
            statuses[i] = record.status;
            timestamps[i] = record.timestamp;
            updatedBy[i] = record.updatedBy;
        }
    }

    function getProductStatus(uint256 productId) public view returns (string memory) {
        return _products[productId].currentStatus;
    }

    function _removeProductFromOwner(address owner, uint256 productId) internal {
        uint256[] storage products = _ownerProducts[owner];
        for (uint i = 0; i < products.length; i++) {
            if (products[i] == productId) {
                products[i] = products[products.length - 1];
                products.pop();
                break;
            }
        }
    }

    function _updateStatus(uint256 productId, string memory status, address updater) internal {
        Product storage product = _products[productId];
        product.currentStatus = status;
        product.statusHistory.push(StatusRecord({
            status: status,
            timestamp: block.timestamp,
            updatedBy: updater
        }));
        emit ProductStatusUpdated(productId, status);
    }

    function _isValidTransition(uint256 productId, Lifecycle next) internal view returns (bool) {
        Lifecycle cur = lifecycle[productId];
        address originalProducer = _products[productId].originalOwner;
        address currentActor = msg.sender;

        if (cur == Lifecycle.Returned) {
            return (next == Lifecycle.ReceivedBySupplier);
        }

        if (currentActor == originalProducer) {
            if (cur == Lifecycle.Created) return next == Lifecycle.Packed;
            if (cur == Lifecycle.Packed) return (next == Lifecycle.ShippedToSupplier || next == Lifecycle.ShippedToCustomer);
        }
        return true; 
    }

    function _lifecycleToString(Lifecycle s) internal pure returns (string memory) {
        if (s == Lifecycle.Created)             return "Created";
        if (s == Lifecycle.Packed)              return "Packed";
        if (s == Lifecycle.ShippedToSupplier)   return "ShippedToSupplier";
        if (s == Lifecycle.ShippedToCustomer)   return "ShippedToCustomer";
        if (s == Lifecycle.ReceivedBySupplier)  return "ReceivedBySupplier";
        if (s == Lifecycle.DeliveredToCustomer) return "DeliveredToCustomer";
        if (s == Lifecycle.Returned)            return "Returned";
        if (s == Lifecycle.Expired)             return "Expired";
        return "";
    }

    function _statusToLifecycle(string memory s, address currentActor) internal view returns (bool, Lifecycle) {
        bytes32 h = keccak256(bytes(s));

        if (hasRole(currentActor, SUPPLIER)) {
            if (h == keccak256("Created")) return (true, Lifecycle.Created);
            if (h == keccak256("Packed")) return (true, Lifecycle.Packed);
            if (h == keccak256("ShippedToSupplier")) return (true, Lifecycle.ShippedToSupplier);
            if (h == keccak256("ShippedToCustomer")) return (true, Lifecycle.ShippedToCustomer);
            if (h == keccak256("Returned")) return (true, Lifecycle.Returned); 
            if (h == keccak256("ReceivedBySupplier")) return (true, Lifecycle.ReceivedBySupplier);
        }

    if (hasRole(currentActor, SUPPLIER)) {
        if (h == keccak256("ReceivedBySupplier")) return (true, Lifecycle.ReceivedBySupplier);
        if (h == keccak256("ShippedToSupplier")) return (true, Lifecycle.ShippedToSupplier);
        if (h == keccak256("ShippedToCustomer")) return (true, Lifecycle.ShippedToCustomer);
        if (h == keccak256("Returned")) return (true, Lifecycle.Returned);  
    }

        if (hasRole(currentActor, CUSTOMER)) {
            if (h == keccak256("Returned")) return (true, Lifecycle.Returned);
            if (h == keccak256("Expired")) return (true, Lifecycle.Expired);
            if (h == keccak256("DeliveredToCustomer")) return (true, Lifecycle.DeliveredToCustomer);

        }

        return (false, Lifecycle.Created);
    }

    function _enforceAndSetLifecycle(uint256 productId, Lifecycle next, address updater) internal {
        Lifecycle cur = lifecycle[productId];
        if (cur == next) revert InvalidTransition();
        if (!_isValidTransition(productId, next)) revert InvalidTransition();
        lifecycle[productId] = next;
        _updateStatus(productId, _lifecycleToString(next), updater);
    }
}

/* -------------------------------- SupplyChain --------------------------- */
contract SupplyChain is ERC721URIStorage, ProductManager, Pausable, ReentrancyGuard {
        AggregatorV3Interface internal priceFeed;

    constructor() ERC721("SupplyChainProduct", "SCP") {
        priceFeed = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306); 
    }

    function getETHPrice() public view returns (int) {
        (, int price, , , ) = priceFeed.latestRoundData();
        return price; 
    }

    struct Origin {
        string country;
        string site;
        string batchId;
        string ipfsCid;
    }

    mapping(uint256 => string) public productOrigins;
    mapping(uint256 => Origin) public originInfo;

    function pause() external onlyAdmin { _pause(); }
    function unpause() external onlyAdmin { _unpause(); }

    function createProductAsSupplier(
        string calldata name,
        uint256 price,
        uint256 expiryDate,
        string calldata tokenURI_,
        string calldata origin
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(hasRole(msg.sender, SUPPLIER) || hasRole(msg.sender, ADMIN), "Only supplier or admin");
        require(bytes(tokenURI_).length > 0, "tokenURI empty");
        require(expiryDate == 0 || expiryDate > block.timestamp, "Invalid expiryDate");

        uint256 productId = createProduct(name, price, expiryDate);
        _mint(msg.sender, productId);
        _setTokenURI(productId, tokenURI_);
        productOrigins[productId] = origin;
        return productId;
    }

    function createProductAsSupplierV2(
        string calldata name,
        uint256 price,
        uint256 expiryDate,
        string calldata tokenURI_,
        string calldata origin,
        string calldata storageConditions
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(hasRole(msg.sender, SUPPLIER) || hasRole(msg.sender, ADMIN), "Only supplier or admin");
        require(bytes(tokenURI_).length > 0, "tokenURI empty");
        require(expiryDate == 0 || expiryDate > block.timestamp, "Invalid expiryDate");

        uint256 productId = createProduct(name, price, expiryDate);
        _mint(msg.sender, productId);
        _setTokenURI(productId, tokenURI_);
        productOrigins[productId] = origin;

        _products[productId].storageConditions = storageConditions;
        emit StorageConditionsUpdated(productId, storageConditions);

        return productId;
    }

    function setOriginInfo(
        uint256 productId,
        string calldata country,
        string calldata site,
        string calldata batchId,
        string calldata ipfsCid
    ) external onlyOwnerSupplierAdmin(productId) {
        originInfo[productId] = Origin(country, site, batchId, ipfsCid);
    }


    event ProductStatusLogged(uint256 indexed productId, string currentStatus);

    function depositFunds() external payable {
        require(msg.value > 0, "Amount must be greater than 0");
        userBalances[msg.sender] += msg.value; 
        emit FundsDeposited(msg.sender, msg.value);
    }
    event FundsDeposited(address indexed user, uint256 amount);

    function transferProduct(uint256 productId, address newOwner, address finalCustomerAddr) public nonReentrant {
        Product storage product = _products[productId];
        require(product.owner == msg.sender, "Not the owner");
        require(userBalances[newOwner] >= product.price, "New owner has insufficient balance for this product");
        if (hasRole(newOwner, SUPPLIER)) {
            require(finalCustomerAddr != address(0), "Final customer must be specified for supplier transfers");
            product.finalCustomer = finalCustomerAddr;
        } else {
            product.finalCustomer = newOwner;
        }
        product.previousOwner = msg.sender;
        _removeProductFromOwner(msg.sender, productId);
        product.owner = newOwner;
        _ownerProducts[newOwner].push(productId);
        _logTransaction(productId, "Transfer", msg.sender, newOwner);
        emit ProductTransferred(productId, msg.sender, newOwner);
    }

    function getBalanceOf(address user) external view returns (uint256) {
        return userBalances[user];
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance; 
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        if (hasRole(msg.sender, CUSTOMER)) {
            uint256 totalInTransitValue = 0;
            uint256[] memory myProducts = _ownerProducts[msg.sender];
            for (uint256 i = 0; i < myProducts.length; i++) {
                uint256 productId = myProducts[i];
                Product storage product = _products[productId];
                if (keccak256(bytes(product.currentStatus)) == keccak256(bytes("ShippedToCustomer")) || 
                    keccak256(bytes(product.currentStatus)) == keccak256(bytes("ShippedToSupplier"))) {
                    totalInTransitValue += product.price;
                }
            }
            uint256 availableBalance = userBalances[msg.sender];
            uint256 maxWithdrawableAmount = availableBalance - totalInTransitValue;
            require(amount <= maxWithdrawableAmount, "Insufficient funds: You can't withdraw more than available balance excluding in-transit product values");
            userBalances[msg.sender] -= amount;
            payable(msg.sender).transfer(amount);
            emit FundsWithdrawn(msg.sender, amount); 

        } else {
            require(userBalances[msg.sender] >= amount, "Insufficient balance");
            userBalances[msg.sender] -= amount;
            payable(msg.sender).transfer(amount);
            emit FundsWithdrawn(msg.sender, amount);  
        }
    }

    event FundsWithdrawn(address indexed user, uint256 amount);

    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize)
        internal
        override
    {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
        require(!paused(), "Token transfer while paused");
        if (from != address(0) && from != to) {
            _updateOwnerOnTransfer(from, to, tokenId);
        }
    }

    function _updateOwnerOnTransfer(address from, address to, uint256 tokenId) internal {
        _removeProductFromOwner(from, tokenId);
        _products[tokenId].owner = to;
        _ownerProducts[to].push(tokenId);
        emit ProductTransferred(tokenId, from, to);
    }

    function getAllProducts() external view returns (
        uint256[] memory ids,
        string[] memory names,
        address[] memory owners,
        address[] memory previousOwners,
        address[] memory originalOwners,
        uint256[] memory prices,
        uint256[] memory expiryDates,
        address[] memory returnedToOriginals 
    ) {
        uint256 productCount = _nextProductId - 1;
        ids = new uint256[](productCount);
        names = new string[](productCount);
        owners = new address[](productCount);
        previousOwners = new address[](productCount);
        originalOwners = new address[](productCount);
        prices = new uint256[](productCount);
        expiryDates = new uint256[](productCount);
        returnedToOriginals = new address[](productCount);
        for (uint256 i = 1; i <= productCount; i++) {
            Product storage product = _products[i];
            ids[i - 1] = i;
            names[i - 1] = product.name;
            owners[i - 1] = product.owner;
            previousOwners[i - 1] = product.previousOwner;
            originalOwners[i - 1] = product.originalOwner;
            prices[i - 1] = product.price;
            expiryDates[i - 1] = product.expiryDate;
            returnedToOriginals[i - 1] = product.returnedToOriginalAddr; 
        }
        return (ids, names, owners, previousOwners, originalOwners, prices, expiryDates, returnedToOriginals);
    }
    function returnProduct(uint256 productId) external nonReentrant {
        Product storage product = _products[productId];
        require(product.owner == msg.sender, "Only current owner can return");
        address receiver = product.previousOwner;
        require(receiver != address(0), "No previous owner");
        _removeProductFromOwner(msg.sender, productId);
        product.owner = receiver;
        _ownerProducts[receiver].push(productId);
        if (receiver == product.originalOwner) {
            product.returnedToOriginalAddr = receiver;
        } else {
            product.returnedToOriginalAddr = address(0);
        }
        lifecycle[productId] = Lifecycle.Returned;
        _updateStatus(productId, "Returned", msg.sender);
        emit ProductStatusUpdated(productId, "Returned to previous owner");
    }

    function getProductOwner(uint256 productId) external view returns (address) {
        require(_products[productId].owner != address(0), "Product not found");
        return _products[productId].owner;
    }

    function getStats() external view returns (uint256 registeredProducts, uint256 transactions, uint256 activeSuppliers, uint256 inTransit) {
        uint256 registeredProductsCount = _nextProductId - 1; 
        uint256 transactionsCount = address(this).balance; 
        uint256 activeSuppliersCount = 0;
        uint256 inTransitCount = 0;
        for (uint256 i = 1; i <= registeredProductsCount; i++) {
            address productOwner = _products[i].owner;
            if (hasRole(productOwner, SUPPLIER)) {
                activeSuppliersCount++;
            }
        }
        for (uint256 i = 1; i <= registeredProductsCount; i++) {
            if (
                lifecycle[i] == Lifecycle.ShippedToCustomer || 
                lifecycle[i] == Lifecycle.ShippedToSupplier
            ) {
                inTransitCount++;
            }
        }
        return (registeredProductsCount, transactionsCount, activeSuppliersCount, inTransitCount);
    }

    function getAdvancedStats() external view returns (
        uint256[] memory counts, 
        uint256 totalVolume,      
        uint256 totalProducts,   
        uint256 expiredCount     
    ) {
        uint256 total = _nextProductId - 1;
        counts = new uint256[](8); 
        for (uint256 i = 1; i <= total; i++) {
            counts[uint256(lifecycle[i])]++;
            
            totalVolume += _products[i].price;

            if (lifecycle[i] == Lifecycle.Expired) {
                expiredCount++;
            }
        }
        return (counts, totalVolume, total, expiredCount);
    }

    event ProductDeleted(uint256 indexed productId, address indexed deletedBy);

    function deleteProduct(uint256 productId) external nonReentrant {
        Product storage product = _products[productId];
        address owner = product.owner;
        _burn(productId);
        _removeProductFromOwner(owner, productId);
        delete _products[productId];
        delete lifecycle[productId];
        delete productOrigins[productId];
        delete originInfo[productId];
        _logTransaction(productId, "Deletion", owner, address(0));
        emit ProductDeleted(productId, msg.sender);
    }
}      