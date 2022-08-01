const LaunchSettings = artifacts.require("LaunchSettings");
const LaunchFactory = artifacts.require("LaunchFactory");
module.exports = function (deployer) {
  deployer.deploy(LaunchSettings).then(function(){
    console.log("-----"+LaunchSettings.address);
      return deployer.deploy(LaunchFactory, LaunchSettings.address);
  });
};
