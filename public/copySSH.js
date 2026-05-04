// Get the <pre> element
const SSH = document.getElementById("mySSH");

//Create a copy button element
const copyButtonSSH = document.createElement("span");
copyButtonSSH.innerText = "Copy";
copyButtonSSH.classList.add("copy-button");

// Append the copy button to the <pre> tag
SSH.appendChild(copyButtonSSH);

// Add click event listener to the copy button
copyButtonSSH.addEventListener("click", () => {
  // Hide the copy button temporarily
  copyButtonSSH.style.display = "none";

  // Create a range and select the text inside the <pre> tag
  const range = document.createRange();
  range.selectNode(SSH);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(range);

  try {
    // Copy the selected text to the clipboard
    document.execCommand("copy");

    // Alert the user that the text has been copied
    copyButtonSSH.innerText = "Copied!";
    setTimeout(function(){
      copyButtonSSH.innerText = "Copy";
    }, 2000);
  } catch (err) {
    console.error("Unable to copy text:", err);
  } finally {
    // Show the copy button again
    copyButtonSSH.style.display = "inline";

    // Deselect the text
    window.getSelection().removeAllRanges();
  }
});
